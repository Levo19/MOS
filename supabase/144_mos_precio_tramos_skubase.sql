-- 144 · Tramos de precio ATADOS A sku_base (no a idProducto/codigo_barra) → aplican a TODO el grupo
-- (canónico + presentaciones + equivalentes comparten sku_base). 100% Supabase. Reemplaza el almacenamiento
-- por-fila de mos.productos.segmentos_precio (que dejaba al equivalente sin el tramo).

create table if not exists mos.precio_tramos (
  sku_base    text primary key,
  tramos      jsonb not null default '[]'::jsonb,
  updated_at  timestamptz not null default now(),
  updated_by  text
);
alter table mos.precio_tramos enable row level security;  -- acceso solo vía funciones SECURITY DEFINER

-- bump de catálogo cuando cambian los tramos → ME/MOS re-jalan solos (igual que mos.productos)
drop trigger if exists tg_bump_catversion_tramos on mos.precio_tramos;
create trigger tg_bump_catversion_tramos after insert or delete or update on mos.precio_tramos
  for each statement execute function mos._bump_catalogo_version();

-- write: por skuBase (acepta idProducto por compat → deriva el sku_base). Valida KGM (granel) del grupo.
create or replace function mos.actualizar_segmentos_precio(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_sku   text := nullif(btrim(coalesce(p->>'skuBase', p->>'sku_base','')), '');
  v_id    text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_segs  jsonb := coalesce(p->'segmentos', '[]'::jsonb);
  v_val   jsonb; v_limpios jsonb; v_canon record;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sku is null and v_id is not null then
    select sku_base into v_sku from mos.productos where id_producto = v_id limit 1;
  end if;
  if v_sku is null then return jsonb_build_object('ok',false,'error','skuBase requerido'); end if;

  v_val := mos._validar_segmentos_precio(v_segs);
  if not (v_val->>'ok')::boolean then return v_val; end if;
  v_limpios := v_val->'segmentos';

  -- el grupo debe tener un canónico KGM (los tramos son volumétricos, solo para graneles)
  select * into v_canon from mos.productos
   where sku_base = v_sku and coalesce(nullif(factor_conversion,0),1)=1
   order by (upper(coalesce(unidad_medida,''))='KGM') desc nulls last limit 1;
  if not found then return jsonb_build_object('ok',false,'error','sku_base sin canónico: '||v_sku); end if;
  if upper(coalesce(v_canon.unidad_medida,'')) <> 'KGM' then
    return jsonb_build_object('ok',false,'error','Solo grupos KGM (granel) admiten tramos · este es '||coalesce(nullif(upper(v_canon.unidad_medida),''),'sin unidad'));
  end if;

  if jsonb_array_length(v_limpios) = 0 then
    delete from mos.precio_tramos where sku_base = v_sku;   -- vaciar = borrar el grupo
  else
    insert into mos.precio_tramos (sku_base, tramos, updated_at, updated_by)
    values (v_sku, v_limpios, now(), coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'admin'))
    on conflict (sku_base) do update set tramos=excluded.tramos, updated_at=now(), updated_by=excluded.updated_by;
  end if;

  return jsonb_build_object('ok', true, 'skuBase', v_sku, 'segmentos', v_limpios, 'total', jsonb_array_length(v_limpios));
end;$fn$;

revoke all on function mos.actualizar_segmentos_precio(jsonb) from public;
grant execute on function mos.actualizar_segmentos_precio(jsonb) to service_role, authenticated, anon;
