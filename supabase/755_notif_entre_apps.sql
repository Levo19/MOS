-- 755 · Notificaciones entre apps (diseño RETOMA_notificaciones_entre_apps.md, decisiones
-- del dueño 2026-08-11; implementación autorizada 2026-08-12).
-- (1) Preingreso creado en WH → push también a apps:['mosExpress'] (cajeros/vendedores).
--     El ticket impreso en caja SE QUEDA: son dos canales. Audiencia por APP, no por rol
--     (los cajeros de ME son identidades virtuales MEX:* que no viven en mos.personal).
-- (2) Cambio de PRECIO → aviso AGRUPADO cada 5 min (texto aprobado por el dueño):
--     "💲 Precios actualizados · 9 productos: A, B, C… y 6 más".
--     Cola mos.notif_precio_pendiente + trigger best-effort sobre mos.historial_precio_costo
--     (SOLO tipo='PRECIO': COSTO es confidencial y TRAMOS son flags) + cron cada 5 min.
--     Un fallo del aviso JAMÁS tumba el guardado de un precio.
-- PN: SIN CAMBIOS (decisión: solo al aprobarse, ya funciona).

-- ═══ (1) preingreso → push a ME además de MASTER/ADMIN ═══════════════════════
CREATE OR REPLACE FUNCTION wh.crear_preingreso(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id     text := nullif(btrim(coalesce(p->>'id_preingreso','')), '');
  v_prov   text := coalesce(p->>'id_proveedor','');
  v_carg   text := coalesce(p->>'cargadores','');
  v_usuario text := coalesce(p->>'usuario','');
  v_monto  numeric := wh._num(p->>'monto');
  v_fotos  text := coalesce(p->>'fotos','');
  v_coment text := coalesce(p->>'comentario','');
  v_fecha  timestamptz := wh._ts(p->>'fecha', now());
  v_cuerpo text;
begin
  if coalesce((select valor from mos.config where clave='WH_CREAR_PREINGRESO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_CREAR_PREINGRESO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;  -- [B2]
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- idempotencia (retry/doble-tap no duplica el preingreso)
  if exists (select 1 from wh.preingresos where id_preingreso = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'id_preingreso',v_id);
  end if;

  insert into wh.preingresos (id_preingreso, fecha, id_proveedor, cargadores, usuario, monto, fotos, comentario, estado, id_guia)
  values (v_id, v_fecha, v_prov, v_carg, v_usuario, v_monto, v_fotos, v_coment, 'PENDIENTE', '');

  -- [740] cuerpo con NOMBRE del proveedor (no el código) — calculado UNA vez para ambos avisos
  v_cuerpo := coalesce(
      (select nullif(btrim(pr.nombre),'') from mos.proveedores pr
        where btrim(pr.id_proveedor) = btrim(v_prov) limit 1),
      case when nullif(btrim(v_prov),'') is not null then 'prov. '||btrim(v_prov) else 'Proveedor sin identificar' end)
    || ' · S/ ' || to_char(coalesce(v_monto,0),'FM999999990.00')
    || case when nullif(btrim(v_usuario),'') is not null then ' · '||btrim(v_usuario) else '' end;

  begin perform mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
    'titulo', '📦 Preingreso nuevo',
    'cuerpo', v_cuerpo,
    'data', jsonb_build_object('tipo','wh_preingreso'))); exception when others then null; end;

  -- [755] también a los de ME (cajeros/vendedores): audiencia por APP — el ticket
  -- impreso en caja se mantiene (es el que se pega); esto es el canal en el celular.
  begin perform mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('apps', jsonb_build_array('mosExpress')),
    'titulo', '📦 Llegó mercadería al almacén',
    'cuerpo', v_cuerpo,
    'data', jsonb_build_object('tipo','wh_preingreso'))); exception when others then null; end;

  return jsonb_build_object('ok',true,'dedup',false,'id_preingreso',v_id);
end;
$function$;

-- ═══ (2) precios: cola + trigger + cron agrupador ═════════════════════════════
create table if not exists mos.notif_precio_pendiente (
  id          bigserial primary key,
  sku_base    text not null default '',
  id_producto text not null default '',
  nombre      text not null default '',
  ts          timestamptz not null default now(),
  enviado_en  timestamptz
);
create index if not exists idx_notif_precio_pend on mos.notif_precio_pendiente (enviado_en) where enviado_en is null;

create or replace function mos._tg_notif_precio()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  -- SOLO precio de venta. COSTO jamás se anuncia (confidencial); TRAMOS son flags.
  if upper(coalesce(new.tipo,'')) = 'PRECIO' then
    insert into mos.notif_precio_pendiente (sku_base, id_producto, nombre)
    values (
      coalesce(new.sku_base,''), coalesce(new.id_producto,''),
      coalesce(
        (select p2.descripcion from mos.productos p2 where p2.id_producto = new.id_producto limit 1),
        (select p2.descripcion from mos.productos p2
          where p2.sku_base = new.sku_base and coalesce(p2.factor_conversion,1) = 1 limit 1),
        nullif(new.sku_base,''), ''));
  end if;
  return new;
exception when others then
  return new;   -- best-effort: un fallo del aviso JAMÁS tumba el guardado del precio
end;
$function$;

drop trigger if exists tg_notif_precio on mos.historial_precio_costo;
create trigger tg_notif_precio
  after insert on mos.historial_precio_costo
  for each row execute function mos._tg_notif_precio();

create or replace function mos.cron_avisar_precios()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_max     bigint;
  v_nombres text[];
  v_n       int;
  v_cuerpo  text;
begin
  select max(id) into v_max from mos.notif_precio_pendiente where enviado_en is null;
  if v_max is null then return jsonb_build_object('ok', true, 'enviado', false); end if;

  -- dedup por producto (varios cambios del mismo producto en la ventana → 1 mención)
  select array_agg(nombre order by nombre) into v_nombres
    from (select distinct upper(coalesce(nullif(btrim(nombre),''), nullif(btrim(sku_base),''), 'PRODUCTO')) as nombre
            from mos.notif_precio_pendiente
           where enviado_en is null and id <= v_max) s;
  v_n := coalesce(array_length(v_nombres, 1), 0);
  if v_n = 0 then
    update mos.notif_precio_pendiente set enviado_en = now() where enviado_en is null and id <= v_max;
    return jsonb_build_object('ok', true, 'enviado', false);
  end if;

  -- Texto aprobado por el dueño: "9 productos: A, B, C… y 6 más"
  v_cuerpo := v_n || ' producto' || case when v_n = 1 then '' else 's' end || ': '
    || array_to_string(v_nombres[1:3], ', ')
    || case when v_n > 3 then '… y ' || (v_n - 3) || ' más' else '' end;

  perform mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('apps', jsonb_build_array('mosExpress')),
    'titulo', '💲 Precios actualizados',
    'cuerpo', v_cuerpo,
    'data', jsonb_build_object('tipo', 'me_precios')));

  update mos.notif_precio_pendiente set enviado_en = now() where enviado_en is null and id <= v_max;
  return jsonb_build_object('ok', true, 'enviado', true, 'productos', v_n, 'cuerpo', v_cuerpo);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$function$;

-- cron cada 5 min (idempotente: re-agenda si ya existe)
do $do$
begin
  begin perform cron.unschedule('mos-avisar-precios'); exception when others then null; end;
  perform cron.schedule('mos-avisar-precios', '*/5 * * * *', 'select mos.cron_avisar_precios();');
end;
$do$;
