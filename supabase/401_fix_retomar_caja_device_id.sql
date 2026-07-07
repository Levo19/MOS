-- 401 · FIX retomar_caja_device: matchear por dispositivo_id, NO por printnode_id.
-- Bug: la RPC comparaba `coalesce(printnode_id,'') = deviceId` → printnode_id es el ID de la IMPRESORA
-- (ej. 75287158), nunca el deviceId del equipo (UUID) → SIEMPRE devolvía encontrada:false. Efecto: si un
-- equipo perdía su config local (reload/limpieza/reset), NUNCA se le ofrecía "Tu caja sigue abierta" y
-- quedaba forzado a "inicia sesión" (perdiendo el puntero a su caja ABIERTA). me.cajas.dispositivo_id SÍ
-- guarda el UUID del equipo que abrió la caja. Cero-GAS.

create or replace function me.retomar_caja_device(p jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $function$
declare
  v_dev  text := nullif(btrim(coalesce(p->>'deviceId','')),'');
  v_caja me.cajas%rowtype;
begin
  if coalesce(me.jwt_app(),'') not in ('mosExpress','MOS') then
    return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA','encontrada',false);
  end if;
  if v_dev is null then
    return jsonb_build_object('status','error','error','deviceId requerido','encontrada',false);
  end if;
  select * into v_caja from me.cajas
  where upper(coalesce(estado,''))='ABIERTA' and coalesce(dispositivo_id,'')=v_dev   -- [fix 401] device, no impresora
    and to_char(fecha_apertura at time zone 'America/Lima','YYYY-MM-DD')=to_char(now() at time zone 'America/Lima','YYYY-MM-DD')
  order by fecha_apertura desc nulls last, created_at desc nulls last limit 1;
  if not found then return jsonb_build_object('status','success','encontrada',false); end if;
  return jsonb_build_object('status','success','encontrada',true,
    'idCaja',coalesce(v_caja.id_caja,''), 'vendedor',coalesce(v_caja.vendedor,''),
    'zona',coalesce(v_caja.zona_id,''), 'monto',coalesce(v_caja.monto_inicial,0),
    'fechaApertura', case when v_caja.fecha_apertura is not null then to_char(v_caja.fecha_apertura at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') else '' end,
    'estacion', jsonb_build_object('Estacion_Codigo',coalesce(v_caja.estacion,''),'Estacion_Nombre',coalesce(v_caja.estacion,''),'PrintNode_ID',coalesce(nullif(v_caja.printnode_id,''),v_dev)));
end; $function$;

grant execute on function me.retomar_caja_device(jsonb) to authenticated, service_role, anon;
