-- [979] MosGo — ATRIBUCIÓN DE VENDEDOR en el Catálogo Virtual (lookbook).
--  Idea del dueño: cada vendedor comparte SU link (…/catalogo.html?v=<slug>); el cliente que entra por ahí
--  ve el nombre del asesor, el botón de WhatsApp escribe a SU número, y si arma un carrito la solicitud
--  queda ETIQUETADA a ese vendedor → solo él la ve/atiende. Un MASTER puede activar "ver otros vendedores"
--  para verlas todas e incluso jalarlas. Nada de dinero: solo ruteo de leads del catálogo.

-- 1) mos.personal: teléfono del vendedor + slug "bonito" para el link.
alter table mos.personal add column if not exists telefono  text;
alter table mos.personal add column if not exists catv_slug text;

-- slug para quienes no lo tengan: nombre-apellido sin acentos, minúsculas, separado por guiones.
update mos.personal p set catv_slug = sub.slug
from (
  select id_personal,
         nullif(btrim(regexp_replace(
           lower(translate(
             coalesce(nombre,'') || '-' || coalesce(apellido,''),
             'áàäâãéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ',
             'aaaaaeeeeiiiiooooouuuuncAAAAAEEEEIIIIOOOOOUUUUNC')),
           '[^a-z0-9]+', '-', 'g'), '-'), '') as slug
  from mos.personal
) sub
where p.id_personal = sub.id_personal
  and (p.catv_slug is null or p.catv_slug = '')
  and sub.slug is not null;

-- Luis Vásquez (OP004): teléfono y slug fijos (pedido del dueño).
update mos.personal set telefono = '987320381', catv_slug = 'luis-vasquez' where id_personal = 'OP004';

-- unicidad del slug (parcial: solo donde hay slug).
create unique index if not exists personal_catv_slug_uk on mos.personal (catv_slug) where catv_slug is not null;

-- 2) La solicitud del lookbook guarda a su dueño.
alter table mos.catv_solicitudes add column if not exists id_vendedor text;
create index if not exists catv_solic_vend_ix on mos.catv_solicitudes (id_vendedor) where id_vendedor is not null;

-- 3) RPC público: datos del vendedor por slug (lookbook) o por id (MosGo). Devuelve SOLO lo necesario
--    (nombre visible + teléfono público del asesor). El teléfono es público a propósito: es el que el
--    cliente usa para contactarlo; no expone pin, documento ni nada sensible.
create or replace function mos.catv_vendedor(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_slug text := lower(nullif(btrim(coalesce(p->>'slug', p->>'v', '')), ''));
  v_id   text := nullif(btrim(coalesce(p->>'id', '')), '');
  r record;
begin
  if v_slug is null and v_id is null then return jsonb_build_object('ok', false); end if;
  select id_personal, nombre, apellido, telefono, catv_slug, rol into r
    from mos.personal
   where estado is true
     and ( (v_slug is not null and lower(catv_slug) = v_slug)
        or (v_id   is not null and id_personal = v_id) )
   limit 1;
  if not found then return jsonb_build_object('ok', false); end if;
  return jsonb_build_object('ok', true,
    'id',       r.id_personal,
    'nombre',   btrim(coalesce(r.nombre, '') || ' ' || coalesce(r.apellido, '')),
    'telefono', nullif(regexp_replace(coalesce(r.telefono, ''), '[^0-9]', '', 'g'), ''),
    'slug',     r.catv_slug,
    'esMaster', upper(coalesce(r.rol, '')) = 'MASTER');
end; $fn$;

-- 4) catv_solicitar: acepta el dueño (id_vendedor directo o v=slug del link) y lo guarda. Si no matchea
--    un vendedor activo, queda NULL (pozo común, como antes). Idéntica al original salvo esas 3 líneas.
create or replace function mos.catv_solicitar(p jsonb)
 returns jsonb language plpgsql security definer set search_path to '' set statement_timeout to '20s'
as $function$
declare
  v_in     jsonb   := coalesce(p->'lineas', '[]'::jsonb);
  v_nombre text    := left(btrim(regexp_replace(coalesce(p->>'nombre', ''), '[[:space:]]+', ' ', 'g')), 80);
  v_tel    text    := left(regexp_replace(coalesce(p->>'telefono', ''), '[^0-9]', '', 'g'), 20);
  v_ua     text    := left(btrim(coalesce(p->>'ua', '')), 400);
  v_vend   text    := nullif(btrim(coalesce(p->>'id_vendedor', '')), '');           -- [979] dueño por id
  v_vslug  text    := lower(nullif(btrim(coalesce(p->>'v', '')), ''));              -- [979] o por slug del link
  v_n      int;
  v_hits   int;
  v_cat    jsonb;
  v_map    jsonb;
  v_lin    jsonb   := '[]'::jsonb;
  v_tot    numeric := 0;
  v_fam    jsonb;
  v_esc    jsonb;
  v_fsku   text;
  v_cod    text;
  v_sku    text;
  v_fac    numeric;
  v_pre    numeric;
  v_sub    numeric;
  v_codigo text;
  r        record;
begin
  if jsonb_typeof(v_in) <> 'array' then
    return jsonb_build_object('ok', false, 'razon', 'payload');
  end if;
  v_n := jsonb_array_length(v_in);
  if v_n = 0  then return jsonb_build_object('ok', false, 'razon', 'vacio');      end if;
  if v_n > 60 then return jsonb_build_object('ok', false, 'razon', 'max_lineas'); end if;

  if v_nombre = '' then
    return jsonb_build_object('ok', false, 'razon', 'nombre');
  end if;

  if exists (
    select 1 from jsonb_array_elements(v_in) x
     where coalesce(x.value->>'id', '')          !~ '^[0-9a-f]{10}$'
        or coalesce(x.value->>'escalon_idx', '') !~ '^[0-9]{1,3}$'
        or coalesce(x.value->>'cantidad', '')    !~ '^[0-9]{1,4}$'
  ) then
    return jsonb_build_object('ok', false, 'razon', 'payload');
  end if;

  if exists (
    select 1 from jsonb_array_elements(v_in) x
     where (x.value->>'cantidad')::int < 1 or (x.value->>'cantidad')::int > 999
  ) then
    return jsonb_build_object('ok', false, 'razon', 'cantidad');
  end if;

  select count(*) into v_hits
    from mos.catv_solicitudes s
   where s.created_at > now() - interval '1 hour'
     and ( (v_tel <> '' and s.telefono   = v_tel)
        or (v_ua  <> '' and s.user_agent = v_ua) );
  if v_hits >= 5 then
    return jsonb_build_object('ok', false, 'razon', 'limite');
  end if;

  -- [979] resolver el dueño de la solicitud (por id directo o por slug del link).
  if v_vend is not null then
    if not exists (select 1 from mos.personal where id_personal = v_vend and estado is true) then v_vend := null; end if;
  elsif v_vslug is not null then
    select id_personal into v_vend from mos.personal where estado is true and lower(catv_slug) = v_vslug limit 1;
  end if;

  v_cat := mos.catalogo_virtual();

  select coalesce(jsonb_object_agg(substr(md5(k.fsku), 1, 10), k.fsku), '{}'::jsonb)
    into v_map
    from (
      select distinct coalesce(nullif(btrim(pp.sku_base), ''), pp.id_producto) as fsku
        from mos.productos pp
       where pp.canal_mayoreo = true and pp.tipo_producto::text <> 'PRESENTACION'
      union
      select distinct nullif(btrim(pp.sku_base), '')
        from mos.productos pp
       where pp.canal_mayoreo = true and pp.tipo_producto::text = 'PRESENTACION'
         and nullif(btrim(pp.sku_base), '') is not null
    ) k;

  for r in
    select x.value->>'id'                as hid,
           (x.value->>'escalon_idx')::int as eidx,
           (x.value->>'cantidad')::int    as cant,
           x.ordinality::int              as nro
      from jsonb_array_elements(v_in) with ordinality x(value, ordinality)
  loop
    select y.value into v_fam
      from jsonb_array_elements(v_cat->'familias') y
     where y.value->>'id' = r.hid
     limit 1;
    if v_fam is null then
      return jsonb_build_object('ok', false, 'razon', 'linea_invalida', 'linea', r.nro);
    end if;

    v_esc := v_fam->'escalones'->r.eidx;
    if v_esc is null then
      return jsonb_build_object('ok', false, 'razon', 'linea_invalida', 'linea', r.nro);
    end if;

    v_fac := coalesce((v_esc->>'factor')::numeric, 1);
    v_pre := round(coalesce((v_esc->>'precio')::numeric, 0), 2);
    if not (v_pre > 0) then
      return jsonb_build_object('ok', false, 'razon', 'linea_invalida', 'linea', r.nro);
    end if;
    v_sub := round(v_pre * r.cant, 2);

    v_fsku := v_map->>r.hid;
    v_cod := null; v_sku := null;
    if v_fsku is not null then
      if v_fac = 1 then
        select pr.codigo_barra, pr.id_producto into v_cod, v_sku
          from mos.productos pr
         where coalesce(nullif(btrim(pr.sku_base), ''), pr.id_producto) = v_fsku
           and pr.tipo_producto::text <> 'PRESENTACION'
           and coalesce(nullif(pr.factor_conversion, 0), 1) = 1
           and pr.canal_mayoreo = true
           and round(coalesce(pr.precio_venta, 0), 2) = v_pre
         order by (upper(coalesce(nullif(btrim(pr.unidad_medida), ''), pr.unidad, '')) = 'KGM') desc,
                  pr.id_producto
         limit 1;
      end if;
      if v_cod is null then
        select e.codigo_barra, e.id_producto into v_cod, v_sku
          from mos.productos e
         where nullif(btrim(e.sku_base), '') = v_fsku
           and e.tipo_producto::text = 'PRESENTACION'
           and e.canal_mayoreo = true
           and coalesce(nullif(e.factor_conversion, 0), 1) = v_fac
           and round(coalesce(e.precio_venta, 0), 2) = v_pre
         order by e.id_producto
         limit 1;
      end if;
    end if;
    if v_cod is null then
      return jsonb_build_object('ok', false, 'razon', 'linea_invalida', 'linea', r.nro);
    end if;

    v_lin := v_lin || jsonb_build_object(
      'n',           r.nro,
      'id',          r.hid,
      'cod_barras',  v_cod,
      'sku',         v_sku,
      'producto',    v_fam->>'nombre',
      'marca',       v_fam->>'marca',
      'concepto',    v_fam->>'concepto',
      'unidad',      v_fam->>'unidad',
      'escalon',     v_esc->>'label',
      'factor',      v_fac,
      'cantidad',    r.cant,
      'precio_unit', v_pre,
      'subtotal',    v_sub);
    v_tot := v_tot + v_sub;
  end loop;

  insert into mos.catv_solicitudes (lineas, total, nombre, telefono, user_agent, id_vendedor)
  values (v_lin, round(v_tot, 2), nullif(v_nombre, ''), nullif(v_tel, ''), nullif(v_ua, ''), v_vend)
  returning codigo into v_codigo;

  return jsonb_build_object('ok', true, 'codigo', v_codigo,
                            'total', round(v_tot, 2), 'lineas', jsonb_array_length(v_lin));
end;
$function$;

-- 5) catv_pendientes: cada vendedor ve SOLO las suyas + el pozo sin dueño; un MASTER puede pedir verOtros
--    para verlas todas (y jalarlas). Devuelve id_vendedor y el nombre del dueño para pintar la card.
create or replace function mos.catv_pendientes(p jsonb default '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to '' set statement_timeout to '15s'
as $function$
declare
  v_rol text := lower(coalesce(nullif(current_setting('role', true), 'none'), session_user::text, ''));
  v_dev text := nullif(btrim(coalesce(p->>'device', '')), '');
  v_vend text := nullif(btrim(coalesce(p->>'id_vendedor', '')), '');
  v_otros boolean := coalesce((p->>'verOtros')::boolean, false);
  v_esMaster boolean := false;
begin
  if v_rol not in ('authenticated', 'service_role', 'postgres')
     and not exists (select 1 from mos.dispositivos d
                      where d.id_dispositivo = v_dev
                        and upper(coalesce(d.estado, '')) = 'ACTIVO'
                        and lower(coalesce(d.app, '')) = 'mosgo')
  then
    return jsonb_build_object('ok', false, 'error', 'NO_AUTORIZADO');
  end if;

  if v_vend is not null then
    select upper(coalesce(rol, '')) = 'MASTER' into v_esMaster from mos.personal where id_personal = v_vend limit 1;
  end if;
  v_otros := v_otros and v_esMaster;   -- "ver otros" solo lo respeta un MASTER

  return jsonb_build_object('ok', true, 'esMaster', v_esMaster, 'verOtros', v_otros, 'solicitudes', coalesce((
    select jsonb_agg(jsonb_build_object(
             'codigo',     s.codigo,
             'nombre',     s.nombre,
             'telefono',   s.telefono,
             'total',      s.total,
             'lineas',     s.lineas,
             'id_vendedor', s.id_vendedor,
             'vendedor',   (select btrim(coalesce(pe.nombre, '') || ' ' || coalesce(pe.apellido, ''))
                              from mos.personal pe where pe.id_personal = s.id_vendedor),
             'created_at', to_char(s.created_at at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI:SS'),
             'hace_min',   floor(extract(epoch from (now() - s.created_at)) / 60)::int
           ) order by s.created_at desc)
      from (select * from mos.catv_solicitudes
             where estado = 'PENDIENTE'
               and ( v_otros                        -- MASTER viendo todo
                  or v_vend is null                 -- sin identidad (compat) → ve todo
                  or id_vendedor = v_vend           -- las suyas
                  or id_vendedor is null )          -- pozo común sin dueño
             order by created_at desc limit 100) s
  ), '[]'::jsonb));
end;
$function$;

select '979 mosgo vendedor lookbook listo' as ok;
