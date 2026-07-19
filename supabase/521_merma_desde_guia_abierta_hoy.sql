-- 521_merma_desde_guia_abierta_hoy.sql — AJUSTE del dueño (uso real):
-- ════════════════════════════════════════════════════════════════════════════════════════
-- "Solo se puede enviar a mermas productos RECIBIDOS de guías de HOY y ABIERTAS" (las guías
-- tienen tiempo de espera / autocierre). Cambia la semántica de 517:
--   ANTES: guía CERRADA (stock ya ingresó) → merma descontaba stock.
--   AHORA: guía ABIERTA de HOY (Lima) → la parte dañada se RESTA de la línea (split): al
--   cerrar la guía ingresa SOLO lo sano. La merma nunca entra al stock vendible
--   (stock_descontado=true → recuperarla SÍ acredita stock; eliminarla es documental).
--   Trazabilidad: wh.mermas.id_guia referencia la guía; total devuelto = línea + mermas.
create or replace function wh.merma_desde_guia(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'id_merma','')), '');
  v_guia  text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_cod   text := nullif(btrim(coalesce(p->>'cod_producto','')), '');
  v_cant  numeric := wh._num(p->>'cantidad');
  v_culpa text := upper(nullif(btrim(coalesce(p->>'culpa','')), ''));
  v_foto  text := coalesce(p->>'foto','');
  v_usr   text := coalesce(p->>'usuario','');
  v_mot   text := coalesce(p->>'motivo','devolución de zona en mal estado');
  v_g     record; v_d record;
begin
  if not wh._claim_ok() and not mos._claim_ok() then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_guia is null or v_cod is null then
    return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_cant <= 0 then return jsonb_build_object('ok',false,'error','CANTIDAD_INVALIDA'); end if;
  if v_foto = '' then return jsonb_build_object('ok',false,'error','FOTO_OBLIGATORIA'); end if;
  if v_culpa not in ('ZONA','ALMACEN') then
    return jsonb_build_object('ok',false,'error','CULPA_INVALIDA'); end if;

  if exists (select 1 from wh.mermas where id_merma = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'id_merma',v_id); end if;

  select * into v_g from wh.guias where id_guia = v_guia;
  if not found or upper(coalesce(v_g.tipo,'')) <> 'INGRESO_DEVOLUCION_ZONA' then
    return jsonb_build_object('ok',false,'error','GUIA_INVALIDA','detalle','solo guías de devolución de zona'); end if;
  -- [Dueño] SOLO guías ABIERTAS y de HOY (Lima) — la ventana de trabajo de la devolución
  if upper(coalesce(v_g.estado,'')) <> 'ABIERTA' then
    return jsonb_build_object('ok',false,'error','GUIA_NO_ABIERTA','detalle','la guía ya cerró — las mermas se separan mientras la devolución está abierta'); end if;
  if (v_g.fecha at time zone 'America/Lima')::date <> (now() at time zone 'America/Lima')::date then
    return jsonb_build_object('ok',false,'error','GUIA_NO_ES_DE_HOY','detalle','solo devoluciones del día'); end if;

  select * into v_d from wh.guia_detalle
   where id_guia = v_guia and upper(cod_producto) = upper(v_cod)
     and upper(coalesce(observacion,'')) <> 'ANULADO'
   order by linea limit 1;
  if not found then return jsonb_build_object('ok',false,'error','PRODUCTO_NO_EN_GUIA'); end if;
  if v_cant > coalesce(v_d.cant_recibida,0) then
    return jsonb_build_object('ok',false,'error','CANTIDAD_EXCEDE','detalle','la línea tiene '||coalesce(v_d.cant_recibida,0)); end if;

  -- SPLIT: la parte dañada se RESTA de la línea → al cerrar la guía ingresa solo lo sano.
  -- (No se toca stock: estas unidades nunca entraron al vendible.)
  update wh.guia_detalle
     set cant_recibida = coalesce(cant_recibida,0) - v_cant,
         cant_esperada = greatest(coalesce(cant_esperada,0) - v_cant, 0)
   where id_guia = v_guia and linea = v_d.linea;

  insert into wh.mermas (id_merma, fecha_ingreso, origen, cod_producto, id_lote, cantidad_original,
    cantidad_pendiente, motivo, usuario, id_guia, estado, responsable, cantidad_reparada,
    cantidad_desechada, foto, culpa, costo_unitario, stock_descontado)
  values (v_id, now(), 'DEVOLUCION_ZONA', v_cod, coalesce(v_d.id_lote,''), v_cant, v_cant, v_mot, v_usr,
    v_guia, 'EN_PROCESO',
    case when v_culpa='ZONA' then coalesce(v_g.id_zona,'ZONA') else 'ALMACEN' end,
    0, 0, v_foto,
    case when v_culpa='ZONA' then coalesce(v_g.id_zona,'ZONA') else 'ALMACEN' end,
    coalesce(nullif(v_d.precio_unitario,0),0), true);

  return jsonb_build_object('ok',true,'id_merma',v_id,
    'culpa', case when v_culpa='ZONA' then coalesce(v_g.id_zona,'ZONA') else 'ALMACEN' end,
    'linea_restante', coalesce(v_d.cant_recibida,0) - v_cant);
end; $fn$;
