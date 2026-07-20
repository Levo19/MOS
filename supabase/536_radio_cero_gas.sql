-- 536: RADIO SmartTV 100% Supabase (último consumidor GAS del repo ME).
-- Antes: radio.html → GAS ?accion=radio_productos → Sheet RadioConfig + descargarCatalogo()
--        + me.radio_ventas (ya Supabase desde SQL 325).
-- Ahora: radio.html → GET /rest/v1/rpc/radio_productos (public wrapper, anon) → me.radio_productos()
--        que mergea mos.productos (canónicos V4) + me.radio_ventas() + me.radio_config (tabla
--        sembrada con el snapshot REAL de la hoja RadioConfig del 2026-07-19).
-- La hoja RadioConfig y Radio.gs quedan muertos; la config se edita en me.radio_config.

begin;

-- 1) Config editable (mismo modelo Tipo|Key|Valor de la hoja, que ya conoce el dueño)
create table if not exists me.radio_config (
  id     bigint generated always as identity primary key,
  tipo   text not null,          -- playlist | ticker | destacado | image | cat | config
  key    text not null default '',
  valor  text not null default '',
  activo boolean not null default true,
  updated_at timestamptz not null default now()
);

-- seed idempotente con la config REAL capturada de la hoja (samples SKU_AQUI excluidos)
insert into me.radio_config(tipo, key, valor)
select * from (values
  ('playlist','6-12','TuKJAASAsrs|MAÑANA'),
  ('playlist','12-18','_qGbhF50Di0|TARDE'),
  ('playlist','18-24','wha8eRdxH4E|NOCHE'),
  ('playlist','0-6','wha8eRdxH4E|NOCHE'),
  ('ticker','1','🛒 MOSEXPRESS — abierto todos los días'),
  ('ticker','2','💳 PAGA CON YAPE · PLIN · TARJETA'),
  ('ticker','3','🍺 CERVEZAS HELADAS siempre'),
  ('ticker','4','🥖 PAN RECIÉN HORNEADO en la mañana'),
  ('ticker','5','⭐ SÍGUENOS @MOSEXPRESS'),
  ('config','rotar_estrella_seg','12'),
  ('config','rotar_cards_seg','7')
) v(tipo,key,valor)
where not exists (select 1 from me.radio_config);

alter table me.radio_config enable row level security;  -- sin policies: solo vía RPC definer

-- 2) Categorizador por keyword (mismas reglas que _categorizarRadio del GAS)
create or replace function me._radio_categoria(p_nombre text)
returns text language sql immutable as $$
  select case
    when p_nombre ~* 'cerveza|pilsen|cristal|cusque|corona|heineken|backus' then 'cerveza'
    when p_nombre ~* 'coca ?cola|inca ?kola|sprite|fanta|gaseosa|kola|pepsi|7 ?up' then 'bebidas'
    when p_nombre ~* 'agua|san luis|cielo|san mateo' then 'agua'
    when p_nombre ~* 'jugo|nectar|néctar|frugos|tampico' then 'bebidas'
    when p_nombre ~* '\msal\M|pimienta|comino|paprika|achiote|oregano|orégano|canela|sazonador|condimento|sazon|sazón|ajinomoto|glutamato' then 'especerias'
    when p_nombre ~* 'aceite|oliva|vinagre|aderezo' then 'aderezos'
    when p_nombre ~* 'salsa|ketchup|mayonesa|mostaza|\maji\M|ají|sillao|soya|huancaina' then 'salsas'
    when p_nombre ~* 'atun|atún|conserva|menestra|frijol|lenteja|garbanzo|enlatado' then 'conservas'
    when p_nombre ~* 'chocolate|sublime|princesa|cua ?cua|hershey|kit ?kat|cocoa' then 'chocolate'
    when p_nombre ~* 'galleta|casino|soda field|\mfield\M|oreo|morochas|margarita|wafer' then 'galletas'
    when p_nombre ~* 'papita|chizito|cheese|\mlay|pringles|piqueo|doritos|cheetos|cancha' then 'snacks'
    when p_nombre ~* 'caramelo|chupetin|chupetín|chicle|halls|mentos|gomas' then 'golosinas'
    when p_nombre ~* 'leche|gloria|laive|pura vida|yogur|queso|mantequilla' then 'lacteos'
    when p_nombre ~* '\mpan\M|bagueta|tostada|paneton|panetón' then 'panaderia'
    when p_nombre ~* 'arroz|fideo|azucar|azúcar|harina|avena|quinua|quínua|kiwicha|huevo' then 'abarrotes'
    when p_nombre ~* 'detergente|jabon liquid|lejia|lejía|sapolio|ariel|bolivar|bolívar|lavavajilla' then 'limpieza'
    when p_nombre ~* 'papel higi|higienico|higiénico|toalla|servilleta|kotex|pañal|pampers|\mjabon\M|shampoo|crema dental' then 'higiene'
    when p_nombre ~* 'cigarro|tabaco|hamilton|lucky|marlboro|winston|caribe' then 'cigarros'
    when p_nombre ~* 'helado|donofrio|cassata' then 'helados'
    else 'default' end;
$$;

-- 3) RPC todo-en-uno (misma forma de salida que el GAS radioProductos)
create or replace function me.radio_productos()
returns jsonb
language plpgsql stable security definer set search_path to ''
as $function$
declare
  v_top jsonb; v_cfg record; v_out jsonb;
  v_playlists jsonb; v_ticker jsonb; v_destacados jsonb; v_config jsonb;
  v_img jsonb; v_cat jsonb;
begin
  v_top := me.radio_ventas();

  -- config desde la tabla
  select coalesce(jsonb_agg(jsonb_build_object(
           'rango', jsonb_build_array(split_part(key,'-',1)::int, split_part(key,'-',2)::int),
           'videoId', split_part(valor,'|',1),
           'nombre', coalesce(nullif(split_part(valor,'|',2),''), 'RADIO')) order by split_part(key,'-',1)::int),'[]'::jsonb)
    into v_playlists from me.radio_config where tipo='playlist' and activo and key ~ '^\d+-\d+$';
  select coalesce(jsonb_agg(valor order by (case when key ~ '^\d+$' then key::int else 999 end)),'[]'::jsonb)
    into v_ticker from me.radio_config where tipo='ticker' and activo and valor<>'';
  select coalesce(jsonb_agg(jsonb_build_object('sku', key, 'prioridad', coalesce(nullif(valor,'')::int, 99)) order by coalesce(nullif(valor,'')::int,99)),'[]'::jsonb)
    into v_destacados from me.radio_config where tipo='destacado' and activo and key<>'' and key<>'SKU_AQUI';
  select coalesce(jsonb_object_agg(key, valor),'{}'::jsonb)
    into v_img from me.radio_config where tipo='image' and activo and key<>'' and key<>'SKU_AQUI' and valor<>'';
  select coalesce(jsonb_object_agg(key, lower(valor)),'{}'::jsonb)
    into v_cat from me.radio_config where tipo in ('cat','categoria') and activo and key<>'' and key<>'SKU_AQUI' and valor<>'';
  select jsonb_build_object(
      'rotarEstrellaSeg', coalesce((select nullif(valor,'')::int from me.radio_config where tipo='config' and key='rotar_estrella_seg' and activo limit 1), 12),
      'rotarCardsSeg',    coalesce((select nullif(valor,'')::int from me.radio_config where tipo='config' and key='rotar_cards_seg' and activo limit 1), 7))
    into v_config;

  -- productos: canónicos habilitados que vende la tienda (skus_de_la_tienda de radio_ventas),
  -- vendidos = rollup de hoy por sku_base; override img/cat por sku_base o codigo_barra.
  with tienda as (
    select jsonb_array_elements_text(coalesce(v_top->'skus_de_la_tienda','[]'::jsonb)) sku_base
  ), vend as (
    select e->>'sku' sku_base, sum(coalesce((e->>'vendidos')::numeric,0)) vendidos
      from jsonb_array_elements(coalesce(v_top->'productos','[]'::jsonb)) e group by 1
  ), prods as (
    select p.codigo_barra sku,
           upper(p.descripcion) nombre,
           coalesce(p.precio_venta,0)::numeric precio,
           coalesce(v.vendidos,0) vendidos,
           coalesce(v_cat->>p.codigo_barra, v_cat->>p.sku_base, me._radio_categoria(p.descripcion)) categoria,
           coalesce(v_img->>p.codigo_barra, v_img->>p.sku_base, '') img
      from mos.productos p
      join tienda t on t.sku_base = p.sku_base
      left join vend v on v.sku_base = p.sku_base
     where p.tipo_producto = 'CANONICO' and p.estado = true
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.vendidos desc, x.nombre),'[]'::jsonb)
    into v_out
    from (select * from prods order by vendidos desc, nombre limit 300) x;

  return jsonb_build_object(
    'status','ok',
    'productos', v_out,
    'playlists', v_playlists,
    'ticker',    v_ticker,
    'destacados',v_destacados,
    'config',    v_config);
end $function$;

-- 4) wrapper public para GET simple desde la TV (sin headers de schema)
create or replace function public.radio_productos()
returns jsonb language sql stable security definer set search_path to ''
as $$ select me.radio_productos(); $$;

revoke all on function me.radio_productos() from public;
revoke all on function public.radio_productos() from public;
grant execute on function me.radio_productos() to anon, authenticated, service_role;
grant execute on function public.radio_productos() to anon, authenticated, service_role;

commit;
