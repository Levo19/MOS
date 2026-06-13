-- 40_wh_crear_auditoria.sql — [PASO 4] Pieza de auditar_producto: inserta fila en wh.auditorias.
-- ⚠️ INERTE: flag WH_CREAR_AUDITORIA_DIRECTO. Replica asignarAuditoria/auditarProducto (Productos.gs).
-- El ajuste de stock por diferencia lo hace wh.crear_ajuste (ya existe). Idempotente por id_auditoria.

insert into mos.config (clave, valor, descripcion) values
  ('WH_CREAR_AUDITORIA_DIRECTO','0','WH: crear auditoria directo (pieza de auditar_producto).')
on conflict (clave) do nothing;

create or replace function wh.crear_auditoria(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'id_auditoria','')), '');
  v_cod   text := nullif(btrim(coalesce(p->>'codigo_producto','')), '');
  v_fasig timestamptz := wh._ts(p->>'fecha_asignacion', now());
  v_fejec timestamptz := wh._ts(p->>'fecha_ejecucion', null);
begin
  if coalesce((select valor from mos.config where clave='WH_CREAR_AUDITORIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_CREAR_AUDITORIA_DIRECTO_OFF');
  end if;
  if v_id is null or v_cod is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  if exists (select 1 from wh.auditorias where id_auditoria = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'id_auditoria',v_id);
  end if;

  insert into wh.auditorias (id_auditoria, fecha_asignacion, cod_producto, usuario, stock_sistema, stock_fisico,
    diferencia, resultado, observacion, estado, fecha_ejecucion)
  values (v_id, v_fasig, v_cod, coalesce(p->>'usuario',''),
    wh._num(p->>'stock_sistema'), wh._num(p->>'stock_fisico'), wh._num(p->>'diferencia'),
    coalesce(p->>'resultado',''), coalesce(p->>'observacion',''),
    coalesce(nullif(p->>'estado',''),'ASIGNADA'), v_fejec);

  return jsonb_build_object('ok',true,'dedup',false,'id_auditoria',v_id);
end;
$fn$;

revoke all on function wh.crear_auditoria(jsonb) from public;
grant execute on function wh.crear_auditoria(jsonb) to service_role;
