-- ============================================================================================================
-- 284_me_buscar_clientes_frecuentes.sql — buscador de clientes frecuentes por nombre/doc (para el modal MOS)
-- ------------------------------------------------------------------------------------------------------------
-- ME busca clientes filtrando su cache local de CLIENTES_FRECUENTES; MOS (panel admin) no tiene ese cache, así
-- que para replicar el buscador inteligente de ME en el modal "editar cliente" de MOS, exponemos una búsqueda
-- server-side sobre me.clientes_frecuentes. Por NOMBRE (ilike) o por DOCUMENTO (prefijo). No-secreto (nombres/
-- docs de clientes para autocompletar). Gate: token del ecosistema (MOS o ME), NO anon.
-- ============================================================================================================
create schema if not exists me;

create or replace function me.buscar_clientes_frecuentes(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select jsonb_build_object('ok', true, 'data', coalesce((
    select jsonb_agg(row order by row->>'nombre')
    from (
      select jsonb_build_object(
               -- OJO: tipo_doc en la hoja = tipo de COMPROBANTE (BOLETA/NOTA_DE_VENTA), NO el id-type SUNAT (1/6/4).
               'documento', c.documento,
               'nombre',    coalesce(c.nombre,''),
               'tipoComprobante', coalesce(c.tipo_doc,''),
               'direccion', coalesce(c.direccion,'')
             ) as row
      from me.clientes_frecuentes c, (
        select lower(btrim(coalesce(p->>'q',''))) as qn,
               btrim(coalesce(p->>'q','')) as qd
      ) q
      where char_length(q.qn) >= 2
        and ( lower(coalesce(c.nombre,'')) like '%'||q.qn||'%'
              or (q.qd ~ '^\d+$' and c.documento like q.qd||'%') )
      limit 12
    ) s
  ), '[]'::jsonb));
$fn$;
revoke all on function me.buscar_clientes_frecuentes(jsonb) from public;
grant execute on function me.buscar_clientes_frecuentes(jsonb) to authenticated, service_role;
