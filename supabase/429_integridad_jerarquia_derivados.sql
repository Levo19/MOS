-- 429 · [catálogo v4 · RONDA 3] INTEGRIDAD DE LA JERARQUÍA granel → derivados
-- Pedido del dueño: "no se puede eliminar el padre antes que los hijos".
-- Los derivados cuelgan por codigo_producto_base (= skuBase | idProducto del granel):
-- borrar el granel dejaría derivados HUÉRFANOS (envasado WH sin origen, analítica rota).
--
-- Diseño (statement-level con transition table): si el MISMO delete incluye padre E hijos
-- (purga de grupo completa) SÍ pasa; solo bloquea cuando quedarían huérfanos VIVOS.
-- Bypass para scripts: set_config('mos.skip_cb_guard','1') — el mismo GUC del 426.

-- 1) No borrar un granel dejando derivados vivos
create or replace function mos._tg_no_huerfanos_derivados()
returns trigger language plpgsql security definer set search_path='' as $fn$
declare v_huerfano record;
begin
  if coalesce(current_setting('mos.skip_cb_guard', true),'') = '1' then return null; end if;
  select d.id_producto, d.descripcion, b.descripcion as padre
    into v_huerfano
  from mos.productos d
  join borrados b
    on upper(btrim(coalesce(d.codigo_producto_base,'')))
       in (upper(coalesce(nullif(btrim(b.sku_base),''), b.id_producto)), upper(b.id_producto))
  where coalesce(nullif(btrim(d.codigo_producto_base),''),'') <> ''
    -- el hijo debe seguir VIVO (no venir en el mismo delete)
    and not exists (select 1 from borrados b2 where b2.id_producto = d.id_producto)
  limit 1;
  if found then
    raise exception 'TIENE_DERIVADOS: no puedes eliminar "%" — su derivado "%" (%) sigue vivo. Elimina primero los hijos.',
      v_huerfano.padre, v_huerfano.descripcion, v_huerfano.id_producto;
  end if;
  return null;
end; $fn$;

drop trigger if exists tg_no_huerfanos_derivados on mos.productos;
create trigger tg_no_huerfanos_derivados
  after delete on mos.productos
  referencing old table as borrados
  for each statement execute function mos._tg_no_huerfanos_derivados();

-- 2) No cambiar la unidad de un granel (KGM/peso → unidad) mientras tenga derivados:
--    romperías la porción kg de TODOS los hijos y el kg_equiv de rotación/analítica.
create or replace function mos._tg_granel_unidad_con_derivados()
returns trigger language plpgsql security definer set search_path='' as $fn$
declare v_n int;
begin
  if coalesce(current_setting('mos.skip_cb_guard', true),'') = '1' then return new; end if;
  if upper(coalesce(old.unidad_medida,'')) in ('KGM','KG','LTR','L','GR','G')
     and upper(coalesce(new.unidad_medida,'')) not in ('KGM','KG','LTR','L','GR','G') then
    select count(*) into v_n from mos.productos d
     where upper(btrim(coalesce(d.codigo_producto_base,'')))
           in (upper(coalesce(nullif(btrim(old.sku_base),''), old.id_producto)), upper(old.id_producto));
    if v_n > 0 then
      raise exception 'GRANEL_CON_DERIVADOS: "%" tiene % derivado(s) que dependen de su unidad de peso — no se puede cambiar a %',
        old.descripcion, v_n, new.unidad_medida;
    end if;
  end if;
  return new;
end; $fn$;

drop trigger if exists tg_granel_unidad_con_derivados on mos.productos;
create trigger tg_granel_unidad_con_derivados
  before update of unidad_medida on mos.productos
  for each row execute function mos._tg_granel_unidad_con_derivados();
