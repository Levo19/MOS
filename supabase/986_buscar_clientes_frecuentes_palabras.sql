-- [986] Búsqueda de clientes frecuentes MÁS INTELIGENTE: por PALABRAS (todas presentes, orden libre).
--  Antes hacía substring de una sola cadena → "luis vasquez" NO encontraba "LUIS ENRRIQUE VASQUEZ OSTOS".
--  Ahora: si la búsqueda es numérica → prefijo del documento (estricto, como debe ser un DNI/RUC); si es texto
--  → parte en palabras y exige que TODAS estén en el nombre (en cualquier orden). Solo lectura, sin token.
create or replace function me.buscar_clientes_frecuentes(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $function$
  select jsonb_build_object('ok', true, 'data', coalesce((
    select jsonb_agg(row order by row->>'nombre')
    from (
      select jsonb_build_object(
               'documento', c.documento,
               'nombre',    coalesce(c.nombre,''),
               'tipoComprobante', coalesce(c.tipo_doc,''),
               'tipoId',    coalesce(c.tipo_id,''),
               'direccion', coalesce(c.direccion,'')
             ) as row
      from me.clientes_frecuentes c, (
        select lower(btrim(coalesce(p->>'q',''))) as qn,
               btrim(coalesce(p->>'q','')) as qd
      ) q
      where char_length(q.qn) >= 2
        and case
              when q.qd ~ '^\d+$'
                then c.documento like q.qd || '%'                     -- búsqueda numérica → prefijo del documento
              else not exists (                                       -- texto → TODAS las palabras en el nombre
                select 1 from unnest(regexp_split_to_array(q.qn, '\s+')) w
                where btrim(w) <> '' and lower(coalesce(c.nombre,'')) not like '%' || btrim(w) || '%'
              )
            end
      limit 12
    ) s
  ), '[]'::jsonb));
$function$;

select '986 buscar_clientes_frecuentes por palabras listo' as ok;
