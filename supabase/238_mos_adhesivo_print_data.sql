-- ════════════════════════════════════════════════════════════════════════════
-- 238 · #5 Stage 2: RPC de datos para el Edge de impresión + seed de calibración
-- ════════════════════════════════════════════════════════════════════════════
-- mos.adhesivo_print_data(id) bundlea TODO lo que el Edge necesita en 1 round-trip:
-- json de la plantilla + mapa de iconos + printNodeId de la impresora ADHESIVO +
-- params de calibración. mos.adhesivo_inc_prints(qty) incrementa el contador de drift
-- tras una impresión OK (espeja _adhIncrementarPrintsCount del GAS).
-- ════════════════════════════════════════════════════════════════════════════

-- Seed de las claves de calibración faltantes (defaults del GAS). GAP ya existe ('3').
insert into mos.config (clave, valor) values
  ('ADHESIVO_DENSITY', '8'),
  ('ADHESIVO_SPEED', '4'),
  ('ADHESIVO_OFFSET_Y', '0'),
  ('ADHESIVO_DRIFT_DOTS_POR_PRINT', '0'),
  ('ADHESIVO_PRINTS_DESDE_CAL', '0')
on conflict (clave) do nothing;

create or replace function mos.adhesivo_print_data(p_id text)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_json   jsonb;
  v_nombre text;
  v_iconos jsonb;
  v_printer text;
  v_cfg    jsonb;
begin
  select json, nombre into v_json, v_nombre
    from mos.adhesivo_plantillas where id_plantilla = p_id and activo;
  if v_json is null then return jsonb_build_object('ok', false, 'error', 'no encontrada o inactiva: ' || p_id); end if;

  select coalesce(jsonb_object_agg(id_icono || '__' || tamano_dots, hex), '{}'::jsonb)
    into v_iconos from mos.adhesivo_iconos;

  -- impresora: tipo ADHESIVO activa con printNodeId; preferir id_zona=ALMACEN (espeja _adhGetPrinterNodeId)
  select printnode_id into v_printer from mos.impresoras
   where upper(coalesce(tipo,'')) = 'ADHESIVO' and activo and coalesce(btrim(printnode_id),'') <> ''
   order by (id_zona = 'ALMACEN') desc nulls last
   limit 1;
  if v_printer is null then return jsonb_build_object('ok', false, 'error', 'sin impresora ADHESIVO activa con printNodeId'); end if;

  select jsonb_object_agg(clave, valor) into v_cfg from mos.config where clave like 'ADHESIVO\_%';

  return jsonb_build_object(
    'ok', true,
    'nombre', v_nombre,
    'json', v_json,
    'iconos', v_iconos,
    'printerId', v_printer,
    'calib', jsonb_build_object(
      'gapMm',       coalesce(nullif(btrim(v_cfg->>'ADHESIVO_GAP_MM'),'')::numeric, 2),
      'density',     coalesce(nullif(btrim(v_cfg->>'ADHESIVO_DENSITY'),'')::int, 8),
      'speed',       coalesce(nullif(btrim(v_cfg->>'ADHESIVO_SPEED'),'')::int, 4),
      'offsetBase',  coalesce(nullif(btrim(v_cfg->>'ADHESIVO_OFFSET_Y'),'')::numeric, 0),
      'drift',       coalesce(nullif(btrim(v_cfg->>'ADHESIVO_DRIFT_DOTS_POR_PRINT'),'')::numeric, 0),
      'printsCount', coalesce(nullif(btrim(v_cfg->>'ADHESIVO_PRINTS_DESDE_CAL'),'')::int, 0)
    ));
end;
$fn$;

create or replace function mos.adhesivo_inc_prints(p_qty int)
returns void language plpgsql security definer set search_path = '' as $fn$
begin
  update mos.config set valor = (coalesce(nullif(btrim(valor),'')::int, 0) + p_qty)::text
   where clave = 'ADHESIVO_PRINTS_DESDE_CAL';
  if not found then
    insert into mos.config (clave, valor) values ('ADHESIVO_PRINTS_DESDE_CAL', p_qty::text);
  end if;
end;
$fn$;

revoke all on function mos.adhesivo_print_data(text) from public;
revoke all on function mos.adhesivo_inc_prints(int)  from public;
grant execute on function mos.adhesivo_print_data(text) to authenticated, service_role;
grant execute on function mos.adhesivo_inc_prints(int)  to authenticated, service_role;

notify pgrst, 'reload schema';
