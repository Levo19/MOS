-- 776 · FIX TRIBUTARIO CRÍTICO: exonerados facturaban como gravados (14-ago-2026).
-- Hallazgo del dueño ("muchos de mis graneles son exonerados — ¿cómo lo hace NubeFact?").
-- Evidencia: 130 productos con tipo_igv=2 (exonerado interno) y 4,856 líneas de venta
-- en 30 días TODAS gravadas; 49 exonerados vendieron 427 unidades con IGV indebido.
-- CAUSA RAÍZ: mos._conv_tipo_igv traducía PALABRAS ('exonerado'→9) pero mos.productos
-- .tipo_igv guarda NÚMEROS internos (1=Gravado 2=Exonerado 3=Inafecto) → '2' no
-- matcheaba ninguna palabra → else → 1 (gravado) para TODO el catálogo POS.
-- El resto de la cadena está sana y usa el catálogo NubeFact real:
--   ME: valor_unitario = precio (sin desglose) para 9/11, /1.18 para 1, /1.04 para 8-IVAP
--   Edge emitir-cpe: 1→total_gravada · 8→total_ivap · 9/10→total_exonerada · 11+→total_inafecta
-- Mapa NubeFact (catálogo 07): 1=Gravado onerosa · 8=Gravado IVAP · 9=Exonerado onerosa ·
-- 10=Exonerado gratuito · 11=Inafecto onerosa · 17=Exportación.
CREATE OR REPLACE FUNCTION mos._conv_tipo_igv(p text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case
    -- [776] códigos INTERNOS numéricos (mos.productos.tipo_igv smallint): 1/2/3
    when btrim(coalesce(p,'')) = '2' then 9    -- interno Exonerado → NubeFact 9
    when btrim(coalesce(p,'')) = '3' then 11   -- interno Inafecto  → NubeFact 11
    -- códigos NubeFact ya-convertidos (8..17): pasan tal cual
    when btrim(coalesce(p,'')) ~ '^(8|9|1[0-7])$' then btrim(p)::int
    -- palabras (compatibilidad con el formato viejo)
    when lower(coalesce(p,'')) = 'exonerado' then 9
    when lower(coalesce(p,'')) = 'inafecto'  then 11
    when lower(coalesce(p,'')) = 'ivap'      then 8
    else 1
  end
$function$;
