-- ════════════════════════════════════════════════════════════════════
-- 552 — Producto Nuevo: DESCARTAR (ocultar) + REVIVIR al re-escanear.
-- Pedido del dueño: muchos PN son bonificaciones únicas / duplicados / ya
-- existentes que NO se quieren registrar. Se pueden "ocultar" sin registrar.
-- Si el operador WH vuelve a escanear ese código en una guía NUEVA, revive
-- (se crea una fila PENDIENTE nueva por guía → reaparece solo). También se
-- pueden restaurar a mano desde "ver ocultos".
-- ════════════════════════════════════════════════════════════════════

alter table wh.producto_nuevo add column if not exists descartado_por text;
alter table wh.producto_nuevo add column if not exists descartado_at  timestamptz;

-- ── DESCARTAR (ocultar de la lista de pendientes) ──
create or replace function mos.pn_descartar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_id text := nullif(btrim(coalesce(p->>'idProductoNuevo','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idProductoNuevo requerido'); end if;
  update wh.producto_nuevo
     set estado = 'DESCARTADO',
         descartado_por = coalesce(nullif(btrim(coalesce(p->>'usuario','')),''), descartado_por),
         descartado_at  = now()
   where id_producto_nuevo = v_id and upper(coalesce(estado,'')) = 'PENDIENTE';
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','no encontrado o ya no pendiente'); end if;
  return jsonb_build_object('ok',true);
end; $$;

-- ── RESTAURAR (volver a pendiente desde "ocultos") ──
create or replace function mos.pn_restaurar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_id text := nullif(btrim(coalesce(p->>'idProductoNuevo','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idProductoNuevo requerido'); end if;
  update wh.producto_nuevo
     set estado = 'PENDIENTE', descartado_por = null, descartado_at = null, fecha_registro = now()
   where id_producto_nuevo = v_id and upper(coalesce(estado,'')) = 'DESCARTADO';
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','no encontrado o no estaba oculto'); end if;
  return jsonb_build_object('ok',true);
end; $$;

grant execute on function mos.pn_descartar(jsonb)  to anon, authenticated, service_role;
grant execute on function mos.pn_restaurar(jsonb)  to anon, authenticated, service_role;

-- ── REVIVIR en el re-escaneo: wh.registrar_producto_nuevo, si la fila de esa
--    (guía, código) está DESCARTADA, la vuelve a PENDIENTE en vez de crear otra.
--    (En guía distinta ya nacía una fila PENDIENTE nueva → seguía reapareciendo.)
--    Solo se cambia el bloque de match/UPSERT para incluir DESCARTADO y revivir.
create or replace function wh.registrar_producto_nuevo(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_cb    text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_guia  text := nullif(btrim(coalesce(p->>'idGuia','')), '');
  v_cant  numeric := wh._num(p->>'cantidad');
  v_venc  timestamptz := case when nullif(btrim(coalesce(p->>'fechaVencimiento','')),'') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
                              then (p->>'fechaVencimiento')::timestamptz else null end;
  v_exist text; v_exist_estado text; v_id text;
begin
  if coalesce((select valor from mos.config where clave='WH_REGISTRAR_PN_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_REGISTRAR_PN_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_cb is null then v_cb := 'NLEV' || nextval('wh.seq_nlev')::text; end if;

  -- match por (guía, código) en PENDIENTE **o DESCARTADO** (revival): el re-escaneo
  -- de un oculto lo vuelve a la vida en vez de dejar un duplicado muerto.
  if v_guia is not null then
    select id_producto_nuevo, upper(coalesce(estado,'')) into v_exist, v_exist_estado
      from wh.producto_nuevo
     where id_guia = v_guia and upper(codigo_barra) = upper(v_cb)
       and upper(coalesce(estado,'')) in ('PENDIENTE','DESCARTADO')
     order by (upper(coalesce(estado,''))='PENDIENTE') desc, fecha_registro desc
     limit 1;
  end if;

  if v_exist is not null then
    update wh.producto_nuevo set
      marca             = coalesce(nullif(btrim(coalesce(p->>'marca','')),''), marca),
      descripcion       = coalesce(nullif(btrim(coalesce(p->>'descripcion','')),''), descripcion),
      id_categoria      = coalesce(nullif(btrim(coalesce(p->>'idCategoria','')),''), id_categoria),
      unidad            = coalesce(nullif(btrim(coalesce(p->>'unidad','')),''), unidad),
      cantidad          = case when v_cant > 0 then v_cant else cantidad end,
      fecha_vencimiento = coalesce(v_venc, fecha_vencimiento),
      foto              = coalesce(nullif(btrim(coalesce(p->>'foto','')),''), foto),
      usuario           = coalesce(nullif(btrim(coalesce(p->>'usuario','')),''), usuario),
      estado            = 'PENDIENTE',                 -- revive si venía DESCARTADO
      descartado_por    = null, descartado_at = null,
      fecha_registro    = now()
    where id_producto_nuevo = v_exist;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('idProductoNuevo',v_exist,'codigoBarra',v_cb,
      'idempotente',true,'revivido',(v_exist_estado='DESCARTADO')));
  end if;

  v_id := 'PN' || (extract(epoch from clock_timestamp())*1000)::bigint::text;
  insert into wh.producto_nuevo (id_producto_nuevo, id_guia, marca, descripcion, codigo_barra, id_categoria,
    unidad, cantidad, fecha_vencimiento, foto, estado, usuario, fecha_registro, aprobado_por, fecha_aprobacion, observacion)
  values (v_id, coalesce(v_guia,''), coalesce(p->>'marca',''), coalesce(p->>'descripcion',''), v_cb,
    coalesce(p->>'idCategoria',''), coalesce(p->>'unidad',''), v_cant, v_venc,
    coalesce(p->>'foto',''), 'PENDIENTE', coalesce(p->>'usuario',''), now(), '', null, '');
  begin perform mos.emitir_push(jsonb_build_object('audiencia',jsonb_build_object('roles',jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),'titulo','🆕 Producto nuevo por revisar','cuerpo','Código '||coalesce(nullif(v_cb,''),'?')||' · revísalo y apruébalo en el catálogo','data',jsonb_build_object('tipo','wh_producto_nuevo'))); exception when others then null; end;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idProductoNuevo',v_id,'codigoBarra',v_cb,'idempotente',false));
end;
$function$;
