-- 522_sorpresa_solo_hoy.sql — Guard del dueño: "es imposible poner producto sorpresa de ayer".
-- La sorpresa solo tiene sentido en la ventana del despacho: guía SALIDA_ZONA DE HOY (Lima)
-- y con la recepción de zona aún sin cerrar (SORPRESA_TARDE ya cubría lo segundo).
-- Redefine wh.registrar_sorpresa agregando el check de fecha (resto idéntico a 516).
create or replace function wh.registrar_sorpresa(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_orig   numeric;
  v_id     text := nullif(btrim(coalesce(p->>'id_sorpresa','')), '');
  v_guia   text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_cod    text := nullif(btrim(coalesce(p->>'cod_producto','')), '');
  v_delta  numeric := wh._num(p->>'delta');
  v_clave  text := nullif(btrim(coalesce(p->>'clave_admin','')), '');
  v_auth   jsonb;
  v_g      record;
  v_d      record;
  v_ya     record;
  v_nueva  numeric;
  v_costo  numeric;
begin
  if not wh._claim_ok() and not mos._claim_ok() then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_guia is null or v_cod is null or v_delta = 0 then
    return jsonb_build_object('ok',false,'error','PARAMS_INVALIDOS'); end if;

  select * into v_ya from wh.sorpresas where id_sorpresa = v_id;
  if found then return jsonb_build_object('ok',true,'dedup',true,'estado',v_ya.estado); end if;

  v_auth := mos._validar_clave_admin_core(v_clave, 'SORPRESA', v_guia,
              coalesce(p->>'app','WH'), coalesce(p->>'device',''),
              'sorpresa ' || v_cod || ' Δ' || v_delta);
  if coalesce(v_auth->>'autorizado','false') <> 'true' then
    return jsonb_build_object('ok',false,'error','CLAVE_INVALIDA',
             'detalle', coalesce(v_auth->>'error','clave rechazada')); end if;

  select * into v_g from wh.guias where id_guia = v_guia;
  if not found or upper(coalesce(v_g.tipo,'')) <> 'SALIDA_ZONA' then
    return jsonb_build_object('ok',false,'error','GUIA_INVALIDA'); end if;
  -- [Dueño 2026-07-19] solo guías DE HOY: la sorpresa se arma en la ventana del despacho
  if (v_g.fecha at time zone 'America/Lima')::date <> (now() at time zone 'America/Lima')::date then
    return jsonb_build_object('ok',false,'error','GUIA_NO_ES_DE_HOY','detalle','solo despachos del día'); end if;
  if exists (select 1 from me.zona_traslado_verificacion where id_guia = 'WH:' || v_guia) then
    return jsonb_build_object('ok',false,'error','SORPRESA_TARDE','detalle','la zona ya cerró la recepción'); end if;

  select * into v_d from wh.guia_detalle
   where id_guia = v_guia and upper(cod_producto) = upper(v_cod)
   order by linea limit 1;
  if not found then
    return jsonb_build_object('ok',false,'error','PRODUCTO_NO_EN_GUIA'); end if;

  v_orig  := coalesce(v_d.cant_recibida,0);
  v_nueva := v_orig + v_delta;
  if v_nueva < 0 then
    return jsonb_build_object('ok',false,'error','DELTA_EXCEDE','detalle','la línea tiene ' || v_orig); end if;

  update wh.guia_detalle set cant_recibida = v_nueva
   where id_guia = v_guia and linea = v_d.linea;

  if upper(coalesce(v_g.estado,'')) = 'CERRADA' then
    update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) - v_delta,
                        ultima_actualizacion = now()
     where upper(cod_producto) = upper(v_cod);
  end if;

  begin
    select coalesce(nullif(precio_unitario,0),0) into v_costo
      from wh.guia_detalle where id_guia = v_guia and linea = v_d.linea;
  exception when others then v_costo := 0; end;

  insert into wh.sorpresas(id_sorpresa,id_guia,id_zona,cod_producto,descripcion,delta,
                           cant_original,cant_corregida,admin_nombre,costo_unitario)
  values (v_id, v_guia, v_g.id_zona, v_cod, null, v_delta,
          v_orig, v_nueva,
          coalesce(v_auth->>'nombre', nullif(btrim(coalesce(p->>'admin','')),''), 'admin'),
          v_costo);

  return jsonb_build_object('ok',true,'id_sorpresa',v_id,
           'cant_original', v_orig, 'cant_corregida', v_nueva);
end; $fn$;
