-- 866 · El código de IGV que mandaba mal a SUNAT.
--
-- El 14-ago (SQL 776) se corrigió que los exonerados llegaran al POS como gravados. El arreglo
-- era necesario, pero el código elegido estaba equivocado: se mapeó el interno 2 (Exonerado)
-- al 9 de NubeFact. En NubeFact el 9 es INAFECTO — su propio rechazo lo dice con todas las
-- letras: "codigo Tributo: 9998", que es el código SUNAT de inafecto. El exonerado es el 8.
--
-- Consecuencia: el monto se declaraba en total_exonerada mientras la línea decía "inafecto", y
-- NubeFact contestaba "Total INAFECTA debe ser mayor a cero" y rechazaba en pre-validación.
-- Desde ese día, TODO comprobante que contuviera un exonerado quedó sin llegar a SUNAT: 56 en
-- total. La línea de tiempo no deja dudas — hasta el 13-ago casi cero fallas; del 14-ago en
-- adelante, el 100% de las fallas tienen una línea no gravada.
--
-- Catálogo NubeFact (tipo_de_igv):
--    1 = Gravado · Operación onerosa
--    8 = Exonerado · Operación onerosa
--    9 = Inafecto · Operación onerosa
--   17 = IVAP (arroz pilado)
--
-- El catálogo NO se toca: mos.productos guarda códigos INTERNOS (1 gravado, 2 exonerado,
-- 3 inafecto) y esos están bien. Lo que estaba mal era la traducción, y vive en una sola
-- función. Son cinco líneas, no 87 productos.

begin;

create or replace function mos._conv_tipo_igv(p text)
returns integer
language sql
immutable
set search_path to ''
as $$
  select case
    -- códigos INTERNOS numéricos (mos.productos.tipo_igv smallint): 1/2/3
    when btrim(coalesce(p,'')) = '2' then 8    -- interno Exonerado → NubeFact 8  (era 9 = inafecto)
    when btrim(coalesce(p,'')) = '3' then 9    -- interno Inafecto  → NubeFact 9  (era 11)
    -- códigos NubeFact ya-convertidos (8..17): pasan tal cual
    when btrim(coalesce(p,'')) ~ '^(8|9|1[0-7])$' then btrim(p)::int
    -- palabras (compatibilidad con el formato viejo)
    when lower(coalesce(p,'')) = 'exonerado' then 8
    when lower(coalesce(p,'')) = 'inafecto'  then 9
    when lower(coalesce(p,'')) = 'ivap'      then 17   -- era 8, que ahora es exonerado
    else 1
  end
$$;

commit;

-- El caché del catálogo NO se invalida por cambiar una función: guarda el resultado ya
-- calculado. Sin purgarlo, el POS seguiría sirviendo el 9 viejo desde memoria.
delete from mos.catalogo_cache;
select mos.bump_catalogo_version_manual();

-- comprobación: los tres caminos tienen que dar el código correcto
select 'interno 2 (exonerado)' caso, mos._conv_tipo_igv('2') da, 8 esperado
union all select 'interno 3 (inafecto)', mos._conv_tipo_igv('3'), 9
union all select 'palabra exonerado',    mos._conv_tipo_igv('exonerado'), 8
union all select 'palabra inafecto',     mos._conv_tipo_igv('inafecto'), 9
union all select 'palabra ivap',         mos._conv_tipo_igv('ivap'), 17
union all select 'gravado por defecto',  mos._conv_tipo_igv('1'), 1;
