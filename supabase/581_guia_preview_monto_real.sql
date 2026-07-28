-- 581 · [Analítica · feedback] guia_preview: NO inventar el total de la guía.
-- El fallback "suma del detalle" confundía: mostraba el monto de UNA línea (ej. el maní,
-- 50×10=500) como si fuera el total de la guía (que también tiene comino, aún sin costo).
-- Ahora: 'monto' = SOLO el monto_total real de la guía (null si no está cargado). El monto
-- POR LÍNEA (cantidad × precio) lo calcula el front y lo muestra inline en cada ítem.
create or replace function wh.guia_preview(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_g  record;
begin
  if v_id is null then return jsonb_build_object('ok',false,'error','idGuia requerido'); end if;
  select * into v_g from wh.guias where id_guia = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idGuia', v_g.id_guia,
    'fecha',  to_char(v_g.fecha at time zone 'America/Lima','YYYY-MM-DD'),
    'tipo',   coalesce(v_g.tipo,''),
    'proveedor', coalesce(
                   (select pv.nombre from mos.proveedores pv where pv.id_proveedor = v_g.id_proveedor and coalesce(nullif(btrim(pv.nombre),''),'') <> '' limit 1),
                   nullif(btrim(v_g.ocr_razon_social),''),
                   nullif(btrim(v_g.id_proveedor),''), '—'),
    'documento', coalesce(nullif(btrim(v_g.numero_documento),''),''),
    'monto',  nullif(v_g.monto_total, 0),   -- [581] SOLO el total real (o null); sin fallback engañoso
    'foto',   coalesce(nullif(btrim(v_g.foto),''), ''),
    'nItems', (select count(*) from wh.guia_detalle d where d.id_guia = v_id),
    'items',  coalesce((
      select jsonb_agg(x.obj order by x.linea) from (
        select d.linea, jsonb_build_object(
                 'nombre', coalesce((select pr.descripcion from mos.productos pr
                                      where upper(btrim(pr.codigo_barra)) = upper(btrim(d.cod_producto)) limit 1),
                                    d.cod_producto),
                 'cantidad', coalesce(d.cant_recibida, d.cantidad_aplicada, d.cant_esperada, 0),
                 'precio', d.precio_unitario) obj
        from wh.guia_detalle d where d.id_guia = v_id order by d.linea limit 8
      ) x), '[]'::jsonb)
  ));
end; $fn$;

revoke all on function wh.guia_preview(jsonb) from public;
revoke execute on function wh.guia_preview(jsonb) from anon;
grant execute on function wh.guia_preview(jsonb) to authenticated, service_role;
notify pgrst, 'reload schema';
