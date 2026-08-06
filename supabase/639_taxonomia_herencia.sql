
create or replace function mos._tg_herencia_ficha() returns trigger
language plpgsql security definer set search_path to '' as $fn$
declare v_l record;
begin
  if tg_op = 'INSERT' then
    if new.tipo_producto::text = 'CANONICO' then
      if new.categoria_ia is null then
        new.categoria_ia := coalesce(
          mos.clasificar_producto(new.descripcion, new.descripcion_ia),
          case when nullif(btrim(coalesce(new.id_categoria,'')),'') is not null
               then jsonb_build_object('categoria', new.id_categoria, 'subcategoria', 'Por clasificar') end);
      end if;
    elsif new.tipo_producto::text = 'PRESENTACION' then
      -- líder REAL: con ficha > no-PRE legacy > nombre más largo (hay 53 sku con duplicados sucios)
      select marca, descripcion_ia, categoria_ia into v_l from mos.productos
       where sku_base = new.sku_base and tipo_producto::text in ('CANONICO','DERIVADO')
         and codigo_barra is distinct from new.codigo_barra
       order by (descripcion_ia is not null) desc, (codigo_barra !~* '^PRE[0-9]') desc, length(descripcion) desc
       limit 1;
      if found then
        new.descripcion_ia := coalesce(v_l.descripcion_ia, new.descripcion_ia);
        new.categoria_ia   := coalesce(v_l.categoria_ia,   new.categoria_ia);
        if nullif(btrim(coalesce(v_l.marca,'')),'') is not null then new.marca := v_l.marca; end if;
      end if;
    elsif new.tipo_producto::text = 'DERIVADO' then
      select descripcion_ia, categoria_ia into v_l from mos.productos
       where sku_base = new.codigo_producto_base and tipo_producto::text = 'CANONICO'
       order by (descripcion_ia is not null) desc, (codigo_barra !~* '^PRE[0-9]') desc, length(descripcion) desc
       limit 1;
      if found then
        new.descripcion_ia := coalesce(v_l.descripcion_ia, new.descripcion_ia);
        new.categoria_ia   := coalesce(v_l.categoria_ia,   new.categoria_ia);
      end if;
      new.marca := 'TONYS';
    end if;
  elsif tg_op = 'UPDATE' and new.tipo_producto::text = 'CANONICO'
        and (new.descripcion is distinct from old.descripcion
          or new.codigo_barra is distinct from old.codigo_barra) then
    new.categoria_ia := coalesce(mos.clasificar_producto(new.descripcion, new.descripcion_ia), new.categoria_ia);
    new.ia_refresh := true;
  end if;
  return new;
end $fn$;


create or replace function mos._tg_herencia_cascada() returns trigger
language plpgsql security definer set search_path to '' as $fn$
begin
  if pg_trigger_depth() > 4 then return null; end if;
  -- coalesce: un líder SIN ficha (p.ej. fila basura PRE legacy) nunca borra lo heredado
  if new.tipo_producto::text = 'CANONICO' then
    update mos.productos d
       set descripcion_ia = coalesce(new.descripcion_ia, d.descripcion_ia),
           categoria_ia   = coalesce(new.categoria_ia,   d.categoria_ia),
           marca = 'TONYS'
     where d.tipo_producto::text = 'DERIVADO' and d.codigo_producto_base = new.sku_base
       and (coalesce(new.descripcion_ia, d.descripcion_ia) is distinct from d.descripcion_ia
         or coalesce(new.categoria_ia, d.categoria_ia) is distinct from d.categoria_ia
         or coalesce(d.marca,'') <> 'TONYS');
    update mos.productos pr
       set descripcion_ia = coalesce(new.descripcion_ia, pr.descripcion_ia),
           categoria_ia   = coalesce(new.categoria_ia,   pr.categoria_ia),
           marca = case when nullif(btrim(coalesce(new.marca,'')),'') is not null then new.marca else pr.marca end
     where pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = new.sku_base
       and (coalesce(new.descripcion_ia, pr.descripcion_ia) is distinct from pr.descripcion_ia
         or coalesce(new.categoria_ia, pr.categoria_ia) is distinct from pr.categoria_ia
         or (nullif(btrim(coalesce(new.marca,'')),'') is not null and pr.marca is distinct from new.marca));
  elsif new.tipo_producto::text = 'DERIVADO' then
    update mos.productos pr
       set descripcion_ia = coalesce(new.descripcion_ia, pr.descripcion_ia),
           categoria_ia   = coalesce(new.categoria_ia,   pr.categoria_ia),
           marca = 'TONYS'
     where pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = new.sku_base
       and (coalesce(new.descripcion_ia, pr.descripcion_ia) is distinct from pr.descripcion_ia
         or coalesce(new.categoria_ia, pr.categoria_ia) is distinct from pr.categoria_ia
         or coalesce(pr.marca,'') <> 'TONYS');
  end if;
  return null;
end $fn$;

-- re-backfill presentaciones líder real:
-- 
-- update mos.productos pr
--    set descripcion_ia = coalesce(l.descripcion_ia, pr.descripcion_ia),
--        categoria_ia   = coalesce(l.categoria_ia,   pr.categoria_ia),
--        marca = case when nullif(btrim(coalesce(l.marca,'')),'') is not null then l.marca else pr.marca end
--   from (
--     select distinct on (x.sku_base) x.sku_base, x.marca, x.descripcion_ia, x.categoria_ia
--       from mos.productos x
--      where x.tipo_producto::text in ('CANONICO','DERIVADO')
--      order by x.sku_base, (x.descripcion_ia is not null) desc, (x.codigo_barra !~* '^PRE[0-9]') desc, length(x.descripcion) desc
--   ) l
--  where pr.tipo_producto::text = 'PRESENTACION' and l.sku_base = pr.sku_base
--    and (pr.categoria_ia is null or pr.descripcion_ia is null)