-- 350: [CERO-GAS] drift/calibración del rollo adhesivo → escribe mos.config ADHESIVO_* (reemplaza gas
-- aplicarDriftDetectado/resetearDriftEmergencia). Fórmulas idénticas al GAS. Gate operador/admin.
create or replace function mos.adhesivo_aplicar_drift(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_mm numeric; v_prints int; v_dir text; v_dots numeric;
begin
  if v_claim not in ('mosExpress','MOS','warehouseMos','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  begin v_mm := abs(nullif(btrim(coalesce(p->>'mmDesviados','')),'')::numeric); exception when others then v_mm := null; end;
  if v_mm is null then return jsonb_build_object('ok',false,'error','mmDesviados debe ser un número'); end if;
  v_prints := coalesce(nullif(btrim(coalesce(p->>'basadoEnPrints','')),'')::int, 10);
  if v_prints < 1 then return jsonb_build_object('ok',false,'error','basadoEnPrints debe ser >= 1'); end if;
  v_dir := lower(coalesce(nullif(btrim(coalesce(p->>'direccion','')),''),'arriba'));
  v_dots := (v_mm / v_prints) * 8;                    -- 1mm = 8 dots @203dpi
  if v_dir = 'abajo' then v_dots := -v_dots; end if;  -- sentido por dirección
  v_dots := round(v_dots, 1);
  insert into mos.config(clave,valor) values ('ADHESIVO_DRIFT_DOTS_POR_PRINT', v_dots::text)
    on conflict (clave) do update set valor = excluded.valor;
  insert into mos.config(clave,valor) values ('ADHESIVO_PRINTS_DESDE_CAL','0')
    on conflict (clave) do update set valor = '0';   -- compensación desde el próximo print
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'mmDesviados',v_mm,'direccion',v_dir,'basadoEnPrints',v_prints,
    'driftDotsPorPrint',v_dots,'driftMmPorPrint',round(v_dots/8,3)));
end;
$fn$;
revoke all on function mos.adhesivo_aplicar_drift(jsonb) from public;
grant execute on function mos.adhesivo_aplicar_drift(jsonb) to anon, authenticated, service_role;

create or replace function mos.adhesivo_reset_drift(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_drift numeric; v_off numeric; v_prints int;
begin
  if v_claim not in ('mosExpress','MOS','warehouseMos','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(nullif(valor,'')::numeric,0) into v_drift from mos.config where clave='ADHESIVO_DRIFT_DOTS_POR_PRINT';
  select coalesce(nullif(valor,'')::numeric,0) into v_off   from mos.config where clave='ADHESIVO_OFFSET_Y';
  select coalesce(nullif(valor,'')::int,0)     into v_prints from mos.config where clave='ADHESIVO_PRINTS_DESDE_CAL';
  insert into mos.config(clave,valor) values ('ADHESIVO_DRIFT_DOTS_POR_PRINT','0') on conflict (clave) do update set valor='0';
  insert into mos.config(clave,valor) values ('ADHESIVO_OFFSET_Y','0')             on conflict (clave) do update set valor='0';
  insert into mos.config(clave,valor) values ('ADHESIVO_PRINTS_DESDE_CAL','0')     on conflict (clave) do update set valor='0';
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'antes',jsonb_build_object('drift',coalesce(v_drift,0),'offset',coalesce(v_off,0),'prints',coalesce(v_prints,0)),
    'ahora',jsonb_build_object('drift',0,'offset',0,'prints',0),
    'mensaje','Drift y offset reseteados a 0. Próximos prints sin compensación.'));
end;
$fn$;
revoke all on function mos.adhesivo_reset_drift(jsonb) from public;
grant execute on function mos.adhesivo_reset_drift(jsonb) to anon, authenticated, service_role;
