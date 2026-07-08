-- 411 · mos.sugerencia_precio_individual → reemplaza el getSugerenciaPrecioIndividual de GAS (cero-GAS).
-- Sugerencia de precio de venta para una línea de ingreso: precio actual del catálogo + sugerido por margen.
-- El margen sale del producto (margen_pct, margen-sobre-venta 0..1); si no hay, 0.30 por defecto. El front tiene
-- su propio fallback (×1.25) si esto no devuelve nada → esta RPC solo mejora la sugerencia, nunca es vinculante.

create or replace function mos.sugerencia_precio_individual(p jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare
  v_cod  text := btrim(coalesce(p->>'codigoProducto',''));
  v_costo numeric := coalesce((p->>'costoUnitarioBruto')::numeric, 0);
  v_venta numeric; v_margen numeric; v_sug numeric;
begin
  if coalesce(me.jwt_app(),'') not in ('MOS','mosExpress','warehouseMos') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_cod = '' then return jsonb_build_object('ok',false,'error','codigoProducto requerido'); end if;
  select precio_venta, margen_pct into v_venta, v_margen
  from mos.productos where codigo_barra = v_cod order by (estado is true) desc nulls last limit 1;
  -- margen_pct se GUARDA como PORCENTAJE (0..100; front default 25, se muestra con %, y el propio front
  -- divide /100 cuando necesita la fracción — app.js:9461). Normalizar a fracción ANTES de validar; si no,
  -- 30 >= 0.95 → siempre caía al default 0.30 y el margen real del producto nunca se aplicaba (bug 500x).
  -- El `>1` cubre legado guardado como fracción (0.30 se queda 0.30). margen-sobre-venta 0..1.
  if v_margen is not null and v_margen > 1 then v_margen := v_margen / 100.0; end if;
  -- margen válido (0..0.95); si no, 0.30
  if v_margen is null or v_margen <= 0 or v_margen >= 0.95 then v_margen := 0.30; end if;
  if v_costo > 0 then
    v_sug := round(v_costo / (1 - v_margen), 2);   -- margen sobre venta (fórmula del ecosistema)
  else
    v_sug := coalesce(v_venta, 0);                  -- sin costo → deja el actual
  end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'precioVentaActual', coalesce(v_venta,0),
    'precioVentaSugerido', coalesce(v_sug,0),
    'margenUsado', v_margen));
end; $fn$;

grant execute on function mos.sugerencia_precio_individual(jsonb) to authenticated, service_role, anon;
