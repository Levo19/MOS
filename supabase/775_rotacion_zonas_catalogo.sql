-- 775 · Rotación POR ZONA para el catálogo (14-ago-2026, pedido del dueño).
-- "Ya tenemos zona 1 activa: quiero chips de rotación en cada zona y en almacén,
-- en canónico, presentación y derivado. Si zona 2 no rota es porque nunca se
-- vendió — debo verlo visualmente." Ventas ME de las últimas 8 semanas agrupadas
-- por código vendido y zona → unidades/semana. El almacén ya tiene su chip
-- (wh_getRotacionSemanal); esto agrega la mirada por zona.
create or replace function mos.rotacion_zonas_catalogo(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  v_out jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  select coalesce(jsonb_agg(jsonb_build_object('cod', z.cod, 'zona', z.zona, 'upsem', z.upsem)), '[]'::jsonb)
    into v_out
    from (
      select upper(btrim(vd.cod_barras)) as cod,
             v.zona_id as zona,
             -- piso 0.1: si vendió ALGO en 8 semanas jamás debe salir "—" ("nunca se vendió")
             greatest(round(sum(vd.cantidad) / 8.0, 1), 0.1) as upsem
        from me.ventas v
        join me.ventas_detalle vd on vd.id_venta = v.id_venta
       where v.fecha > now() - interval '56 days'
         and coalesce(btrim(vd.cod_barras),'') <> ''
         and coalesce(btrim(v.zona_id),'') <> ''
       group by 1, 2
      having sum(vd.cantidad) > 0
    ) z;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'items', coalesce(v_out, '[]'::jsonb), 'semanas', 8));
end;
$function$;
