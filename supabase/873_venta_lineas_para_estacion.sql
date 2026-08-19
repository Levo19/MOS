-- 873 · Modo Cajero: las líneas del ticket, para que floten alrededor del monto.
-- Solo lo que se muestra: nombre, cantidad, subtotal. Nada de costos ni márgenes.
begin;
create or replace function me.venta_lineas(p jsonb default '{}'::jsonb)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  select case
    when coalesce(me.jwt_app(),'') not in ('mosExpress','MOS')
         and coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'role','') <> 'service_role'
      then jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA')
    else jsonb_build_object('ok', true, 'data', coalesce((
      select jsonb_agg(jsonb_build_object('nombre', d.nombre, 'cantidad', d.cantidad, 'subtotal', d.subtotal, 'um', coalesce(d.unidad_medida,'NIU'))
                       order by d.linea)
        from me.ventas_detalle d
       where d.id_venta = nullif(btrim(coalesce(p->>'idVenta','')),'')
       limit 12), '[]'::jsonb))
  end;
$$;
revoke all on function me.venta_lineas(jsonb) from public;
grant execute on function me.venta_lineas(jsonb) to anon, authenticated, service_role;
commit;
