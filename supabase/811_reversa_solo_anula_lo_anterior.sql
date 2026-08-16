-- 811_reversa_solo_anula_lo_anterior.sql — [DUEÑO] "la guía de mi gráfico dice que solo un
-- producto tiene costo aplicado, pero al entrar a la guía veo que todos los costos SÍ están
-- aplicados. Es una incongruencia, no sé cuál está mal."
--
-- Estaba mal el GRÁFICO, por un error de fechas en mi regla de anulación. El Paso 1 tenía razón.
--
-- LAS DOS FECHAS QUE NO SON COMPARABLES:
--   · una fila de COSTO (source COMPRA) se guarda con `ts` = **fecha de la GUÍA** — doctrina de
--     la casa: el costo vale desde que llegó la mercadería. Para la guía del 30-jul, ts = 30-jul.
--   · una fila de REVERSA (source COMPRA_REVERSA) se guarda con `ts` = **now()**, el momento en
--     que alguien apretó la ✕. Para esa misma guía, 15-ago 05:18.
--
-- La regla decía: "fue revertida si existe una reversa de la misma guía con r.ts >= h.ts". Como
-- la reversa lleva el reloj real y los costos la fecha de la guía, **la reversa queda "después"
-- de TODOS los costos de esa guía, para siempre**. Revertido una vez, ninguna re-aplicación
-- posterior podía volver a contar. Eso marcaba 7 de 8 productos como "sin costo aplicado".
--
-- EVIDENCIA (AJINOMOTO SAZONADOR 250GR, guía del 30-jul, en orden real de escritura):
--   15-ago 05:07  S/1.00   COMPRA
--   15-ago 05:09  S/2.90   COMPRA
--   15-ago 05:18  S/3.42   COMPRA_REVERSA   ← la ✕
--   15-ago 05:22  S/3.40   COMPRA           ← re-aplicado: VÁLIDO
--   … ocho aplicaciones más, hasta 15-ago 18:44
-- El catálogo tiene precio_costo = 3.40, coherente con esas re-aplicaciones.
--
-- FIX: comparar por el momento REAL DE ESCRITURA, que ya vive en `meta->>'registradoEl'` y que
-- el SQL 797 ya usaba para resolver "cuál fue la última palabra sobre este producto en esta
-- guía". Una reversa anula lo aplicado ANTES de ella; lo que se aplique DESPUÉS vale.
--     escrito(fila) = coalesce(wh._ts_safe(meta->>'registradoEl'), ts)

create or replace function mos._costo_anulacion(
  p_sku text, p_guia text, p_valor numeric, p_ts timestamptz,
  p_source text, p_precio_venta numeric, p_costo_vigente numeric,
  p_escrito timestamptz)
returns text language sql stable security definer set search_path to '' as $$
  select case
    -- (A) la fila ES la anulación, no un costo: jamás es un punto de la curva.
    when upper(coalesce(p_source,'')) = 'COMPRA_REVERSA' then 'REVERSION'
    -- (1) [811] una reversa anula lo aplicado ANTES que ella, no lo que vino después. Se compara
    --     por momento de ESCRITURA: el `ts` de un costo es la fecha de la guía y el de una
    --     reversa es el reloj real — compararlos era comparar peras con manzanas.
    when coalesce(p_guia,'') <> '' and exists (
           select 1 from mos.historial_precio_costo r
            where r.sku_base = p_sku and r.id_guia = p_guia
              and upper(coalesce(r.source,'')) = 'COMPRA_REVERSA'
              and coalesce(wh._ts_safe(r.meta->>'registradoEl'), r.ts) > coalesce(p_escrito, p_ts)
         ) then 'COMPRA_REVERTIDA'
    -- (2) monto del bulto cargado como unitario, salvo que sea exactamente el costo vigente:
    --     esa basura tiene que verse para poder corregirla.
    when p_precio_venta > 0 and p_valor >= p_precio_venta and coalesce(p_guia,'') <> ''
         and not (p_costo_vigente > 0 and abs(p_valor - p_costo_vigente) < 0.005)
         then 'MONTO_DE_BULTO'
    else null end;
$$;

grant execute on function mos._costo_anulacion(text,text,numeric,timestamptz,text,numeric,numeric,timestamptz)
  to anon, authenticated, service_role;

-- ── Los cinco consumidores pasan a mandar el momento de escritura ──
-- Cada llamada termina en uno de cuatro sufijos conocidos; se les agrega el 8º argumento y se
-- EXIGE que el número de llamadas parcheadas coincida con el número de llamadas que había.
create or replace function mos._mig811(p_fn text)
returns text language plpgsql as $$
declare
  v_def text; v_new text; v_oid oid; v_llamadas int; v_puestos int;
  c_arg constant text := ', coalesce(wh._ts_safe(h.meta->>''registradoEl''), h.ts))';
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = p_fn order by p.oid limit 1;
  if v_oid is null then raise exception '[811] mos.% no existe', p_fn; end if;
  v_def := pg_get_functiondef(v_oid);

  v_llamadas := (length(v_def) - length(replace(v_def, 'mos._costo_anulacion(', '')))
                / length('mos._costo_anulacion(');
  if v_llamadas = 0 then raise exception '[811] mos.% no llama a la regla', p_fn; end if;

  v_new := v_def;
  v_new := replace(v_new, 'coalesce(v_canon.precio_costo,0))', 'coalesce(v_canon.precio_costo,0)' || c_arg);
  v_new := replace(v_new, 'v_pv, v_pc)',   'v_pv, v_pc'   || c_arg);
  v_new := replace(v_new, 'c2.pv, c2.pc)', 'c2.pv, c2.pc' || c_arg);
  v_new := replace(v_new, 'c.pv, 0)',      'c.pv, 0'      || c_arg);

  v_puestos := (length(v_new) - length(replace(v_new, 'registradoEl', '')))
               / length('registradoEl')
               - (length(v_def) - length(replace(v_def, 'registradoEl', ''))) / length('registradoEl');
  if v_puestos <> v_llamadas then
    raise exception '[811] mos.%: % llamadas a la regla pero se parchearon %', p_fn, v_llamadas, v_puestos;
  end if;

  execute v_new;
  return p_fn || ': ' || v_llamadas || ' llamada(s) actualizadas';
end $$;

select mos._mig811('historial_precio_costo');
select mos._mig811('curva_ingresos');
select mos._mig811('curva_guia_detalle');
select mos._mig811('costo_vigente_de');
select mos._mig811('aplicar_costos_compra');

drop function mos._mig811(text);

-- La versión vieja de 7 argumentos se retira: nadie debe seguir llamando a la regla con fechas
-- que no son comparables entre sí.
drop function if exists mos._costo_anulacion(text,text,numeric,timestamptz,text,numeric,numeric);
