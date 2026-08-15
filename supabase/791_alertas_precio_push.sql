-- 791_alertas_precio_push.sql — [ALERTAS DE PRECIO · push a ME + historial 15 días]
-- Pedido del dueño (2026-08-15): cada vez que se setea un precio nuevo, push a TODOS los
-- dispositivos de ME; y en ME, el botón de etiquetas muestra además el HISTORIAL de todos
-- los cambios de precio de los últimos 15 días.
-- El choke point es mos.historial_precio_costo (576/577): TODOS los caminos que cambian
-- precio (MOS_CATALOGO, MOS_PASO2, REGISTRO_PN) insertan ahí una fila tipo='PRECIO'.
-- → trigger AFTER INSERT = cobertura total, server-side, sin depender del front.
-- El push que disparaba el front de MOS (api.js publicarPrecio→_pushEdgeAudiencia) se
-- RETIRA en 2.43.805 para no duplicar: esta es ahora LA única fuente.

-- ── trigger: push por cambio real de precio ──
create or replace function mos.tg_precio_push() returns trigger
language plpgsql security definer set search_path to ''
as $$
declare
  v_desc  text;
  v_tit   text;
  v_cuerpo text;
begin
  begin
    -- Solo PRECIO, solo cambios reales, sin migraciones/seeds.
    if new.tipo <> 'PRECIO' then return new; end if;
    if coalesce(new.meta->>'migrado','') = 'true' then return new; end if;
    if upper(coalesce(new.source,'')) = 'SEED' then return new; end if;
    if new.valor_anterior is not null and new.valor = new.valor_anterior then return new; end if;

    select descripcion into v_desc from mos.productos where id_producto = new.id_producto limit 1;
    v_desc := coalesce(nullif(btrim(v_desc),''), new.id_producto, new.sku_base, 'Producto');
    v_tit  := '🏷 Precio actualizado';
    v_cuerpo := v_desc ||
      case when new.valor_anterior is not null and new.valor_anterior > 0
           then ' · S/ ' || trim(to_char(new.valor_anterior,'FM99990.00')) || ' → S/ ' || trim(to_char(new.valor,'FM99990.00'))
           else ' · precio S/ ' || trim(to_char(new.valor,'FM99990.00')) end ||
      case when coalesce(new.usuario,'') <> '' then ' · por ' || new.usuario else '' end;

    -- TODOS los dispositivos de ME (audiencia por app, sin filtro de rol).
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('apps', jsonb_build_array('mosExpress')),
      'titulo', v_tit, 'cuerpo', v_cuerpo,
      'data', jsonb_build_object('tipo','etiqueta_nueva','skuBase', coalesce(new.sku_base,''),
                                 'idProducto', coalesce(new.id_producto,''))));
  exception when others then
    null;   -- un push jamás rompe el registro del precio
  end;
  return new;
end;
$$;

drop trigger if exists tg_precio_push on mos.historial_precio_costo;
create trigger tg_precio_push
  after insert on mos.historial_precio_costo
  for each row execute function mos.tg_precio_push();

-- ── RPC: historial de cambios de precio (lista "alertas precio" de ME) ──
create or replace function mos.alertas_precio(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  v_dias int := least(greatest(coalesce((p->>'dias')::int, 15), 1), 60);
  v_items jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'idProducto', h.id_producto,
           'skuBase', h.sku_base,
           'descripcion', coalesce(nullif(btrim(pr.descripcion),''), h.id_producto),
           'codigoBarra', pr.codigo_barra,
           'precioAnterior', h.valor_anterior,
           'precioNuevo', h.valor,
           'usuario', h.usuario,
           'source', h.source,
           'ts', to_char(h.ts at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI')
         ) order by h.ts desc), '[]'::jsonb)
    into v_items
    from (
      select * from mos.historial_precio_costo
       where tipo = 'PRECIO'
         and ts > now() - make_interval(days => v_dias)
         and coalesce(meta->>'migrado','') <> 'true'
         and (valor_anterior is null or valor <> valor_anterior)
       order by ts desc
       limit 300
    ) h
    left join mos.productos pr on pr.id_producto = h.id_producto;
  return jsonb_build_object('ok', true, 'dias', v_dias, 'items', v_items);
end;
$$;

grant execute on function mos.alertas_precio(jsonb) to anon, authenticated, service_role;
