-- [957] SUNAT · Buzón de VOUCHERS de pago/declaración (varios por período) + comparación estimado↔declarado
-- + PLAME + multa. El dueño sube las fotos de las constancias (IGV-Renta y PLAME), el OCR (Gemini, desde el
-- front) propone los montos y el dueño confirma; el card marca la DIFERENCIA vs el estimado del sistema, para
-- vigilar al contador (o detectar una factura que faltó subir).
create table if not exists mos.sunat_voucher (
  id text primary key,
  periodo_mes int not null,
  periodo_anio int not null,
  tipo text not null default 'IGV_RENTA',   -- IGV_RENTA | PLAME
  foto_url text,
  igv numeric default 0,
  renta numeric default 0,
  essalud numeric default 0,                 -- PLAME (EsSalud/ONP)
  nro_orden text,
  nota text,
  subido_por text,
  subido_ts timestamptz not null default now()
);
alter table mos.sunat_voucher add column if not exists afp numeric default 0;   -- AFP/ONP (pensiones)
create index if not exists ix_sunat_voucher_periodo on mos.sunat_voucher(periodo_anio, periodo_mes, tipo);
grant select, insert, delete on mos.sunat_voucher to authenticated, anon, service_role;

-- RMV y nº de personas en planilla (editables). PLAME/AFP se estiman sobre personas × RMV (todos en mínimo).
insert into mos.config(clave, valor) values ('SUNAT_RMV','1130') on conflict (clave) do nothing;
insert into mos.config(clave, valor) values ('PLAME_PERSONAS','5') on conflict (clave) do nothing;

-- PLAME: mismo cronograma que las obligaciones mensuales (por dígito de RUC). Seed 2026 dígito 7 = MENSUAL.
insert into mos.sunat_cronograma (anio, ultimo_digito, periodo_mes, fecha_vence, verificado, tipo)
  select anio, ultimo_digito, periodo_mes, fecha_vence, verificado, 'PLAME'
    from mos.sunat_cronograma where tipo='MENSUAL' and anio=2026 and ultimo_digito=7
  on conflict (anio, ultimo_digito, periodo_mes, tipo) do nothing;

-- registrar / listar / borrar
create or replace function mos.sunat_voucher_registrar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_id text := 'VCH-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS')||'-'||substr(md5(random()::text),1,4);
begin
  insert into mos.sunat_voucher(id, periodo_mes, periodo_anio, tipo, foto_url, igv, renta, essalud, afp, nro_orden, nota, subido_por)
  values (v_id,
    coalesce((p->>'mes')::int, extract(month from now())::int),
    coalesce((p->>'anio')::int, extract(year from now())::int),
    coalesce(nullif(p->>'tipo',''),'IGV_RENTA'),
    p->>'fotoUrl', coalesce((p->>'igv')::numeric,0), coalesce((p->>'renta')::numeric,0),
    coalesce((p->>'essalud')::numeric,0), coalesce((p->>'afp')::numeric,0), p->>'nroOrden', p->>'nota', p->>'usuario');
  return jsonb_build_object('ok', true, 'id', v_id);
end $function$;
create or replace function mos.sunat_voucher_listar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
begin
  return jsonb_build_object('ok', true, 'items', coalesce((select jsonb_agg(jsonb_build_object(
    'id', id, 'tipo', tipo, 'fotoUrl', foto_url, 'igv', igv, 'renta', renta, 'essalud', essalud, 'afp', afp,
    'nroOrden', nro_orden, 'subidoTs', to_char(subido_ts at time zone 'America/Lima','YYYY-MM-DD HH24:MI')
  ) order by subido_ts desc)
    from mos.sunat_voucher where periodo_mes=(p->>'mes')::int and periodo_anio=(p->>'anio')::int), '[]'::jsonb));
end $function$;
create or replace function mos.sunat_voucher_borrar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
begin delete from mos.sunat_voucher where id = p->>'id'; return jsonb_build_object('ok', true); end $function$;
grant execute on function mos.sunat_voucher_registrar(jsonb), mos.sunat_voucher_listar(jsonb), mos.sunat_voucher_borrar(jsonb) to authenticated, anon, service_role;

-- historial: meses CERRADOS del año, estimado (IGV+Renta+PLAME) vs declarado (vouchers)
create or replace function mos.sunat_historial(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_anio int := coalesce((p->>'anio')::int, extract(year from now())::int);
  v_mes_act int := extract(month from now())::int;
  v_anio_act int := extract(year from now())::int;
  v_hasta int := case when v_anio < v_anio_act then 12 else v_mes_act - 1 end;
begin
  if v_hasta < 1 then return jsonb_build_object('ok', true, 'items', '[]'::jsonb); end if;
  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object('mes', m, 'estimado', round(est,2), 'declarado', round(dec,2),
             'diferencia', round(est-dec,2), 'nVouchers', nv) order by m)
    from generate_series(1, v_hasta) m
    cross join lateral (select mos.trib_resumen_mes(jsonb_build_object('mes', m, 'anio', v_anio))->'data' tr) t
    cross join lateral (select
      greatest(0, coalesce((t.tr->>'igvEmitido')::numeric,0) - coalesce((t.tr->>'igvFavor')::numeric,0))
        + coalesce((t.tr->>'rentaMensual')::numeric,0)
        + 0.22 * (coalesce((select valor::numeric from mos.config where clave='SUNAT_RMV'),1130) * coalesce((select valor::numeric from mos.config where clave='PLAME_PERSONAS'),5)) est,
      coalesce((select sum(coalesce(igv,0)+coalesce(renta,0)+coalesce(essalud,0)+coalesce(afp,0)) from mos.sunat_voucher where periodo_mes=m and periodo_anio=v_anio),0) dec,
      coalesce((select count(*) from mos.sunat_voucher where periodo_mes=m and periodo_anio=v_anio),0) nv
    ) c), '[]'::jsonb));
end $function$;
grant execute on function mos.sunat_historial(jsonb) to authenticated, anon, service_role;

select 'sunat vouchers listo' ok;
