-- 88_wh_guia_detalle_operacional.sql — [CARGA INTELIGENTE Guías] Detalle operacional FILTRADO server-side.
--
-- PROBLEMA: _descargarOperacionalDirecto traía wh.guia_detalle COMPLETO vía leer_tabla_rls (sin filtro):
-- jsonb global ~1.72MB crudo / 5726 filas hoy, y CRECE sin techo con el histórico (cada guía suma líneas).
--
-- DISEÑO: devuelve SOLO el detalle de guías que el operacional realmente consume del cache GLOBAL:
--   (a) guías ABIERTA (cualquier edad)  → la PROYECCIÓN (_buildProyeccion) suma sus líneas al stock teórico,
--                                          y el Historial las muestra como "⏳ pendiente" (extras no-aplicados).
--   (b) guías con fecha >= now() - p_dias (default 60, TZ negocio = wh.guias.fecha timestamptz) → cubren:
--       rotación 30d, último-mov, conteo de líneas de la card, y el detalle INSTANTÁNEO al abrir (verDetalle).
-- Las guías CERRADAS VIEJAS (fuera de ventana) NO se precargan: al abrirlas, verDetalle cae a get_guia_rls
-- (per-guía, ya probado). El Historial real sale de wh.stock_movimientos (getHistorialStock) — autoritativo,
-- no de este cache. El chat usa get_guia_rls per-guía → tampoco depende de este global.
--
-- COLUMNAS: full (mismas que leer_tabla_rls) — verDetalle/_mostrarDetalleSheet usan idLote/fechaVencimiento/
-- precioUnitario/idDetalle al abrir una guía reciente. NO recortar columnas o el detalle instantáneo se rompe.
--
-- SHAPE: idéntico a leer_tabla_rls('guia_detalle') → {ok:true, data:[ ...filas crudas snake_case... ]} ordenadas
-- por id_guia, linea. El FRONT mapea con _sbRowsToObjsFront('guia_detalle', data) SIN cambios.
-- Gate wh._claim_ok(). security definer + search_path='' (igual que el resto de wrappers _rls).

create or replace function wh.guia_detalle_operacional(p_dias int default 60)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_out  jsonb;
  v_dias int;
begin
  if not wh._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  -- clamp defensivo: 1..400 días (evita ventanas absurdas / negativas; default 60)
  v_dias := coalesce(p_dias, 60);
  if v_dias < 1   then v_dias := 1;   end if;
  if v_dias > 400 then v_dias := 400; end if;

  select coalesce(jsonb_agg(to_jsonb(d) order by d.id_guia, d.linea), '[]'::jsonb)
    into v_out
    from wh.guia_detalle d
    join wh.guias g on g.id_guia = d.id_guia
   where upper(coalesce(g.estado, '')) = 'ABIERTA'
      or g.fecha >= (now() - make_interval(days => v_dias));

  return jsonb_build_object('ok', true, 'data', v_out);
end;
$fn$;

revoke all on function wh.guia_detalle_operacional(int) from public;
grant execute on function wh.guia_detalle_operacional(int) to authenticated, service_role;
