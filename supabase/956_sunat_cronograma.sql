-- [956] SUNAT · Planificación de declaraciones. Cronograma oficial 2026 (Resolución SUNAT), por último
-- dígito de RUC. INVERSIONES MOS EIRL, RUC 20610714057 → dígito 7 (grupo 6-7). Fechas VERIFICADAS con
-- sunat.gob.pe + rankia (coinciden). "Este mes declaras el período anterior" (IGV F.621 + pago a cuenta renta).
-- La tabla es editable/versionada por año para no hardcodear nada cuando SUNAT publique 2027.
create table if not exists mos.sunat_cronograma (
  anio int not null,
  ultimo_digito int not null,     -- 0..9
  periodo_mes int not null,       -- 1..12 (mes cuyo tributo se declara)
  fecha_vence date not null,
  verificado boolean not null default false,
  tipo text not null default 'MENSUAL',   -- MENSUAL | ANUAL
  primary key (anio, ultimo_digito, periodo_mes, tipo)
);

-- Seed 2026, dígito 7 (grupo 6-7) — período → fecha de vencimiento
insert into mos.sunat_cronograma (anio, ultimo_digito, periodo_mes, fecha_vence, verificado, tipo) values
  (2026, 7,  1, '2026-02-20', true, 'MENSUAL'),
  (2026, 7,  2, '2026-03-20', true, 'MENSUAL'),
  (2026, 7,  3, '2026-04-23', true, 'MENSUAL'),
  (2026, 7,  4, '2026-05-22', true, 'MENSUAL'),
  (2026, 7,  5, '2026-06-19', true, 'MENSUAL'),
  (2026, 7,  6, '2026-07-21', true, 'MENSUAL'),
  (2026, 7,  7, '2026-08-24', true, 'MENSUAL'),
  (2026, 7,  8, '2026-09-21', true, 'MENSUAL'),
  (2026, 7,  9, '2026-10-22', true, 'MENSUAL'),
  (2026, 7, 10, '2026-11-20', true, 'MENSUAL'),
  (2026, 7, 11, '2026-12-23', true, 'MENSUAL'),
  (2026, 7, 12, '2027-01-22', true, 'MENSUAL')
on conflict (anio, ultimo_digito, periodo_mes, tipo) do update
  set fecha_vence = excluded.fecha_vence, verificado = excluded.verificado;

-- Declaración ANUAL de Renta (persona jurídica): la del ejercicio 2025 ya venció (mar-abr 2026). La del
-- ejercicio 2026 la publica SUNAT a inicios de 2027 (~marzo 2027). Se deja como ESTIMADO (verificado=false)
-- para recordar "un mes antes"; se corrige cuando salga la resolución 2027.
insert into mos.sunat_cronograma (anio, ultimo_digito, periodo_mes, fecha_vence, verificado, tipo) values
  (2026, 7, 12, '2027-03-26', false, 'ANUAL')
on conflict (anio, ultimo_digito, periodo_mes, tipo) do nothing;

grant select on mos.sunat_cronograma to authenticated, anon, service_role;

-- ── estado de la próxima declaración (para el card + notificaciones) ──
create or replace function mos.sunat_declaracion_estado(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_ruc text := coalesce((select valor from mos.config where clave='EMPRESA_RUC'), '');
  v_dig int := coalesce(nullif(right(v_ruc,1),'')::int, 7);
  v_hoy date := (now() at time zone 'America/Lima')::date;
  v_mes_act int := extract(month from v_hoy)::int;
  v_anio_act int := extract(year from v_hoy)::int;
  v_pmes int; v_panio int; v_venc_date date; v_verif boolean;   -- último mes CERRADO (el que toca declarar)
  v_cmes int; v_canio int; v_cvenc date; v_finmes date;         -- mes EN CURSO (aún abierto)
  v_tr jsonb; v_igvpag numeric; v_renta numeric; v_plame numeric; v_anual record;
  v_dv_igv numeric; v_dv_renta numeric; v_dv_plame numeric; v_dv_n int;   -- declarado (de los vouchers)
  v_est_tot numeric; v_dec_tot numeric;
begin
  -- El período a declarar es el ÚLTIMO MES CERRADO = mes anterior al actual (no se puede declarar un mes
  -- que aún no termina). La ventana de declaración va desde que cierra ese mes hasta su vencimiento.
  v_pmes  := case when v_mes_act = 1 then 12 else v_mes_act - 1 end;
  v_panio := case when v_mes_act = 1 then v_anio_act - 1 else v_anio_act end;
  select fecha_vence, verificado into v_venc_date, v_verif from mos.sunat_cronograma
   where ultimo_digito=v_dig and tipo='MENSUAL' and periodo_mes=v_pmes and anio=v_panio;
  -- estimado REAL de ese período (se actualiza si suben facturas atrasadas al buzón)
  v_tr := mos.trib_resumen_mes(jsonb_build_object('mes', v_pmes, 'anio', v_panio));
  v_igvpag := greatest(0, coalesce((v_tr->'data'->>'igvEmitido')::numeric,0) - coalesce((v_tr->'data'->>'igvFavor')::numeric,0));
  v_renta  := coalesce((v_tr->'data'->>'rentaMensual')::numeric,0);
  -- PLAME (EsSalud 9% de la planilla del mes) — estimado; el voucher da el real
  v_plame  := round(0.09 * coalesce((select sum(coalesce(monto_base,0)) from mos.liquidaciones_dia
                where extract(month from fecha)=v_pmes and extract(year from fecha)=v_panio),0), 2);
  v_est_tot := v_igvpag + v_renta + v_plame;
  -- DECLARADO real (suma de los vouchers subidos para ese período)
  select coalesce(sum(igv),0), coalesce(sum(renta),0), coalesce(sum(essalud),0), count(*)
    into v_dv_igv, v_dv_renta, v_dv_plame, v_dv_n
    from mos.sunat_voucher where periodo_mes=v_pmes and periodo_anio=v_panio;
  v_dec_tot := coalesce(v_dv_igv,0) + coalesce(v_dv_renta,0) + coalesce(v_dv_plame,0);

  -- mes EN CURSO (se declarará cuando cierre)
  v_cmes := v_mes_act; v_canio := v_anio_act;
  v_finmes := (date_trunc('month', v_hoy) + interval '1 month - 1 day')::date;
  select fecha_vence into v_cvenc from mos.sunat_cronograma
   where ultimo_digito=v_dig and tipo='MENSUAL' and periodo_mes=v_cmes and anio=v_canio;

  select * into v_anual from mos.sunat_cronograma
   where ultimo_digito=v_dig and tipo='ANUAL' and fecha_vence >= v_hoy order by fecha_vence asc limit 1;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'ruc', v_ruc, 'digito', v_dig, 'hoy', to_char(v_hoy,'YYYY-MM-DD'),
    -- período a declarar (último cerrado) con su estimado REAL y estado (vencido si pasó su fecha)
    'periodo', jsonb_build_object(
        'mes', v_pmes, 'anio', v_panio,
        'fechaVence', to_char(v_venc_date,'YYYY-MM-DD'),
        'diasRestantes', (v_venc_date - v_hoy),
        'vencido', (v_venc_date < v_hoy),
        'verificado', coalesce(v_verif,false),
        'estimado', jsonb_build_object('igv',round(v_igvpag,2),'renta',round(v_renta,2),'plame',round(v_plame,2),'total',round(v_est_tot,2)),
        'declarado', jsonb_build_object('igv',round(coalesce(v_dv_igv,0),2),'renta',round(coalesce(v_dv_renta,0),2),'plame',round(coalesce(v_dv_plame,0),2),'total',round(v_dec_tot,2),'nVouchers',coalesce(v_dv_n,0)),
        'diferencia', round(v_est_tot - v_dec_tot, 2),
        'tieneVoucher', (coalesce(v_dv_n,0) > 0),
        'multa', ((v_venc_date < v_hoy) and coalesce(v_dv_n,0) = 0),
        'igvAPagar', round(v_igvpag,2), 'renta', round(v_renta,2), 'totalEstimado', round(v_est_tot,2)),
    -- mes en curso: aún no se declara (no da monto definitivo hasta cerrar)
    'enCurso', jsonb_build_object('mes', v_cmes, 'anio', v_canio,
        'diasCierre', (v_finmes - v_hoy), 'finMes', to_char(v_finmes,'YYYY-MM-DD'),
        'fechaVence', to_char(v_cvenc,'YYYY-MM-DD')),
    'anual', case when v_anual.fecha_vence is null then null else jsonb_build_object(
        'fechaVence', to_char(v_anual.fecha_vence,'YYYY-MM-DD'),
        'diasRestantes', (v_anual.fecha_vence - v_hoy), 'verificado', v_anual.verificado) end,
    'calendario', (select coalesce(jsonb_agg(jsonb_build_object(
        'periodoMes', periodo_mes, 'anio', anio, 'fechaVence', to_char(fecha_vence,'YYYY-MM-DD'),
        'estado', case when periodo_mes=v_pmes and anio=v_panio then 'actual'
                       when fecha_vence < v_hoy then 'pasado' else 'futuro' end
      ) order by periodo_mes), '[]'::jsonb)
      from mos.sunat_cronograma where ultimo_digito=v_dig and tipo='MENSUAL' and anio=v_anio_act) ));
end $function$;
grant execute on function mos.sunat_declaracion_estado(jsonb) to authenticated, anon, service_role;

-- ── recordatorios a admins (7/5/3/2/1/0 días antes del vencimiento mensual + anual a 30/15/7/1) ──
create or replace function mos.cron_sunat_recordar()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v jsonb; v_m jsonb; v_a jsonb; v_d int; v_env boolean := false; v_tot text; v_fv text;
begin
  v := mos.sunat_declaracion_estado('{}'::jsonb)->'data';
  v_m := v->'periodo';
  if v_m is not null then
    v_d := (v_m->>'diasRestantes')::int;
    v_tot := to_char(coalesce((v_m->>'totalEstimado')::numeric,0),'FM999,999,990.00');
    v_fv  := to_char((v_m->>'fechaVence')::date, 'DD/MM');
    if v_d in (7,5,3,2,1,0) then
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN','ASCENDIDO')),
        'titulo', case when v_d=0 then '🔴 HOY vence tu declaración SUNAT'
                       when v_d<=2 then '🔴 Declaración SUNAT en '||v_d||' día'||case when v_d=1 then '' else 's' end
                       else '📋 Declaración SUNAT en '||v_d||' días' end,
        'cuerpo', 'Vence el '||v_fv||' · estimado a pagar S/ '||v_tot||' (IGV + Renta). Declara Fácil F.621.',
        'data', jsonb_build_object('tipo','sunat')));
      v_env := true;
    elsif v_d < 0 and v_d >= -3 then   -- ya venció → recordatorio de que se declare igual
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN','ASCENDIDO')),
        'titulo', '⚫ Declaración SUNAT VENCIDA',
        'cuerpo', 'Venció el '||v_fv||' (hace '||abs(v_d)||' día'||case when abs(v_d)=1 then '' else 's' end||'). Si no la presentaste, hazlo ya para reducir la multa.',
        'data', jsonb_build_object('tipo','sunat')));
      v_env := true;
    end if;
  end if;
  v_a := v->'anual';
  if v_a is not null and (v_a->>'diasRestantes')::int in (30,15,7,1) then
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN','ASCENDIDO')),
      'titulo', '📅 Declaración ANUAL de Renta cerca',
      'cuerpo', 'La declaración jurada anual vence el '||to_char((v_a->>'fechaVence')::date,'DD/MM/YYYY')||' (en '||(v_a->>'diasRestantes')||' días). Ve preparándola.',
      'data', jsonb_build_object('tipo','sunat_anual')));
    v_env := true;
  end if;
  return jsonb_build_object('ok', true, 'enviado', v_env);
exception when others then return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;
grant execute on function mos.cron_sunat_recordar() to authenticated, anon, service_role;

-- diario 9:00 Lima = 14:00 UTC
select cron.schedule('mos-sunat-recordar', '0 14 * * *', 'select mos.cron_sunat_recordar();')
  where not exists (select 1 from cron.job where jobname='mos-sunat-recordar');

select 'sunat cronograma listo' ok;
