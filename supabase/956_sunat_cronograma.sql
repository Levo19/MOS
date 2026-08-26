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
  v_prox record; v_venc record; v_anual record;
  v_pmes int; v_panio int; v_tr jsonb; v_igvpag numeric; v_renta numeric;
begin
  -- MENSUAL próxima: el vencimiento MENSUAL más cercano que aún no pasó (o el de hoy)
  select * into v_prox from mos.sunat_cronograma
   where ultimo_digito=v_dig and tipo='MENSUAL' and fecha_vence >= v_hoy
   order by fecha_vence asc limit 1;
  -- MENSUAL recién vencida (pasó hace ≤12 días) → recordatorio "¿ya declaraste?"
  select * into v_venc from mos.sunat_cronograma
   where ultimo_digito=v_dig and tipo='MENSUAL' and fecha_vence < v_hoy and fecha_vence >= v_hoy - 12
   order by fecha_vence desc limit 1;
  -- ANUAL próxima
  select * into v_anual from mos.sunat_cronograma
   where ultimo_digito=v_dig and tipo='ANUAL' and fecha_vence >= v_hoy
   order by fecha_vence asc limit 1;

  -- período que se declara en la próxima mensual (el mes ANTERIOR al del vencimiento)
  if v_prox.fecha_vence is not null then
    v_pmes  := v_prox.periodo_mes;   -- periodo_mes ya ES el mes que se declara
    v_panio := v_prox.anio;
    v_tr := mos.trib_resumen_mes(jsonb_build_object('mes', v_pmes, 'anio', v_panio));
    v_igvpag := greatest(0, coalesce((v_tr->'data'->>'igvEmitido')::numeric,0) - coalesce((v_tr->'data'->>'igvFavor')::numeric,0));
    v_renta  := coalesce((v_tr->'data'->>'rentaMensual')::numeric,0);
  end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'ruc', v_ruc, 'digito', v_dig, 'hoy', to_char(v_hoy,'YYYY-MM-DD'),
    'mensual', case when v_prox.fecha_vence is null then null else jsonb_build_object(
        'periodoMes', v_pmes, 'periodoAnio', v_panio,
        'fechaVence', to_char(v_prox.fecha_vence,'YYYY-MM-DD'),
        'diasRestantes', (v_prox.fecha_vence - v_hoy),
        'verificado', v_prox.verificado,
        'igvAPagar', round(v_igvpag,2), 'renta', round(v_renta,2), 'totalEstimado', round(v_igvpag + v_renta,2)
      ) end,
    'vencida', case when v_venc.fecha_vence is null then null else jsonb_build_object(
        'periodoMes', v_venc.periodo_mes, 'fechaVence', to_char(v_venc.fecha_vence,'YYYY-MM-DD'),
        'diasPasados', (v_hoy - v_venc.fecha_vence)) end,
    'anual', case when v_anual.fecha_vence is null then null else jsonb_build_object(
        'fechaVence', to_char(v_anual.fecha_vence,'YYYY-MM-DD'),
        'diasRestantes', (v_anual.fecha_vence - v_hoy), 'verificado', v_anual.verificado) end ));
end $function$;
grant execute on function mos.sunat_declaracion_estado(jsonb) to authenticated, anon, service_role;

-- ── recordatorios a admins (7/5/3/2/1/0 días antes del vencimiento mensual + anual a 30/15/7/1) ──
create or replace function mos.cron_sunat_recordar()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v jsonb; v_m jsonb; v_a jsonb; v_d int; v_env boolean := false; v_tot text; v_fv text;
begin
  v := mos.sunat_declaracion_estado('{}'::jsonb)->'data';
  v_m := v->'mensual';
  if v_m is not null then
    v_d := (v_m->>'diasRestantes')::int;
    if v_d in (7,5,3,2,1,0) then
      v_tot := to_char(coalesce((v_m->>'totalEstimado')::numeric,0),'FM999,999,990.00');
      v_fv  := to_char((v_m->>'fechaVence')::date, 'DD/MM');
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN','ASCENDIDO')),
        'titulo', case when v_d=0 then '🔴 HOY vence tu declaración SUNAT'
                       when v_d<=2 then '🔴 Declaración SUNAT en '||v_d||' día'||case when v_d=1 then '' else 's' end
                       else '📋 Declaración SUNAT en '||v_d||' días' end,
        'cuerpo', 'Vence el '||v_fv||' · estimado a pagar S/ '||v_tot||' (IGV + Renta). Declara Fácil F.621.',
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
