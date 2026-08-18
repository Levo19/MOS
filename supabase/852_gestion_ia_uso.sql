-- 852_gestion_ia_uso.sql — CONTABILIDAD DE LA IA
--
-- [DUEÑO] "he hecho muchas recargas en Anthropic este mes. Quiero gestionar el uso de la IA en todo
--  el ecosistema: dónde se usa (lista sombra, OCR, y qué más), y en Configuraciones/MOS una
--  constancia de uso agrupada DÍA POR DÍA: se usaron tantos tokens en tal función, en tal app, eso
--  representa tantos dólares, y con tal modelo — porque sé que no siempre usas los mismos."
--
-- CENSO (dónde se gasta IA hoy, verificado en el código):
--   1. Edge `ia`          — proxy general. Lo usan: WH lista sombra (foto/PDF/texto), WH OCR de
--                           comprobante, WH chat de almacén, MOS resumen de zona.
--   2. Edge `ocr-guia`    — cron wh-ocr-guias cada 10 min · haiku 4.5
--   3. Edge `descripcion-ia` — cron cada 10 min · haiku 4.5
--   4. Edge `sustitutos-ia`  — cron cada 10 min · haiku 4.5
--
-- ANTES DE HOY NO SE GUARDABA NADA: Anthropic factura por tokens y la respuesta de cada llamada
-- trae el `usage`, pero nadie lo miraba. El gasto de días pasados NO se puede reconstruir; esta
-- tabla empieza a contar desde que se despliegan las Edge parcheadas.
--
-- PRECIOS: los publica Anthropic por millón de tokens y CAMBIAN. Por eso viven en una TABLA con
-- fecha de vigencia, no incrustados en el código: cuando cambien, se agrega una fila y los días
-- viejos conservan lo que costaron de verdad.
--   base input · cache write 5m = 1.25× · cache write 1h = 2× · cache read = 0.1× · output
--   (tomado de platform.claude.com/docs/en/about-claude/pricing, 2026-08-17)

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) TARIFARIO (USD por millón de tokens). `patron` se compara con LIKE para que
--    un id con fecha (claude-haiku-4-5-20251001) caiga en su familia sin duplicar filas.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists mos.ia_precios (
  id             bigserial primary key,
  patron         text        not null,
  etiqueta       text        not null,
  usd_in         numeric(10,4) not null,
  usd_out        numeric(10,4) not null,
  usd_cache_w5   numeric(10,4),
  usd_cache_w1h  numeric(10,4),
  usd_cache_r    numeric(10,4),
  vigente_desde  date        not null default date '2000-01-01',
  fuente         text,
  creado_ts      timestamptz not null default now()
);
create index if not exists ix_ia_precios_patron on mos.ia_precios (patron, vigente_desde desc);

insert into mos.ia_precios (patron, etiqueta, usd_in, usd_out, usd_cache_w5, usd_cache_w1h, usd_cache_r, fuente)
select * from (values
  ('claude-haiku-4-5%',   'Haiku 4.5',   1.00,  5.00,  1.25,  2.00,  0.10, 'anthropic 2026-08-17'),
  ('claude-3-5-haiku%',   'Haiku 3.5',   0.80,  4.00,  1.00,  1.60,  0.08, 'anthropic 2026-08-17'),
  ('claude-sonnet-5%',    'Sonnet 5',    2.00, 10.00,  2.50,  4.00,  0.20, 'anthropic 2026-08-17'),
  ('claude-sonnet-4-6%',  'Sonnet 4.6',  3.00, 15.00,  3.75,  6.00,  0.30, 'anthropic 2026-08-17'),
  ('claude-sonnet-4-5%',  'Sonnet 4.5',  3.00, 15.00,  3.75,  6.00,  0.30, 'anthropic 2026-08-17'),
  ('claude-opus-4-5%',    'Opus 4.5',    5.00, 25.00,  6.25, 10.00,  0.50, 'anthropic 2026-08-17'),
  ('claude-opus-5%',      'Opus 5',      5.00, 25.00,  6.25, 10.00,  0.50, 'anthropic 2026-08-17')
) v(patron, etiqueta, usd_in, usd_out, usd_cache_w5, usd_cache_w1h, usd_cache_r, fuente)
where not exists (select 1 from mos.ia_precios p where p.patron = v.patron);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) EL LIBRO: una fila por llamada a la IA.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists mos.ia_uso (
  id            bigserial primary key,
  ts            timestamptz not null default now(),
  dia           date        not null default ((now() at time zone 'America/Lima')::date),
  app           text        not null default '?',   -- MOS · warehouseMos · mosExpress · cron
  funcion       text        not null default '?',   -- listaSombra · ocrGuia · descripcionIA · ...
  modelo        text        not null default '?',
  etiqueta      text,                               -- 'Haiku 4.5' (congelada al momento del uso)
  tok_in        bigint      not null default 0,
  tok_out       bigint      not null default 0,
  tok_cache_w   bigint      not null default 0,
  tok_cache_r   bigint      not null default 0,
  costo_usd     numeric(12,6),
  sin_tarifa    boolean     not null default false, -- modelo sin precio configurado
  ok            boolean     not null default true,
  error         text,
  ms            integer,
  meta          jsonb       not null default '{}'::jsonb
);
create index if not exists ix_ia_uso_dia     on mos.ia_uso (dia desc);
create index if not exists ix_ia_uso_funcion on mos.ia_uso (dia desc, funcion);
alter table mos.ia_uso enable row level security;   -- solo se lee por RPC security definer

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) La tarifa vigente para un modelo en un día. El patrón MÁS LARGO gana
--    (así 'claude-sonnet-4-5%' le gana a un futuro 'claude-sonnet%').
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos._ia_tarifa(p_modelo text, p_dia date)
returns mos.ia_precios language sql stable security definer set search_path to '' as $fn$
  select p.* from mos.ia_precios p
   where lower(coalesce(p_modelo,'')) like lower(p.patron)
     and p.vigente_desde <= coalesce(p_dia, (now() at time zone 'America/Lima')::date)
   order by length(p.patron) desc, p.vigente_desde desc
   limit 1;
$fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) REGISTRAR una llamada. La llaman las Edge Functions con la service role, justo
--    después de recibir la respuesta de Anthropic (que trae el bloque `usage`).
--    Nunca falla hacia afuera: si algo sale mal, devuelve ok:false y la IA sigue
--    funcionando — contabilizar jamás puede tumbar una operación.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos.ia_registrar_uso(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  u        jsonb := coalesce(p->'usage','{}'::jsonb);
  v_mod    text  := nullif(btrim(coalesce(p->>'modelo','')),'');
  v_dia    date  := (now() at time zone 'America/Lima')::date;
  t        mos.ia_precios;
  v_in     bigint := greatest(0, coalesce((u->>'input_tokens')::bigint, 0));
  v_out    bigint := greatest(0, coalesce((u->>'output_tokens')::bigint, 0));
  v_cw     bigint := greatest(0, coalesce((u->>'cache_creation_input_tokens')::bigint, 0));
  v_cr     bigint := greatest(0, coalesce((u->>'cache_read_input_tokens')::bigint, 0));
  v_costo  numeric(12,6); v_id bigint;
begin
  t := mos._ia_tarifa(v_mod, v_dia);
  if t.id is not null then
    -- el write de caché se cobra a la tarifa de 5 min (la que usa el SDK por defecto)
    v_costo := round((
        v_in  * t.usd_in                        +
        v_out * t.usd_out                       +
        v_cw  * coalesce(t.usd_cache_w5, t.usd_in * 1.25) +
        v_cr  * coalesce(t.usd_cache_r,  t.usd_in * 0.10)
      ) / 1000000.0, 6);
  end if;

  insert into mos.ia_uso (app, funcion, modelo, etiqueta, tok_in, tok_out, tok_cache_w, tok_cache_r,
                          costo_usd, sin_tarifa, ok, error, ms, meta)
  values (coalesce(nullif(btrim(coalesce(p->>'app','')),''),'?'),
          coalesce(nullif(btrim(coalesce(p->>'funcion','')),''),'?'),
          coalesce(v_mod,'?'), t.etiqueta, v_in, v_out, v_cw, v_cr,
          v_costo, (t.id is null),
          coalesce((p->>'ok')::boolean, true), nullif(btrim(coalesce(p->>'error','')),''),
          nullif(p->>'ms','')::int, coalesce(p->'meta','{}'::jsonb))
  returning id into v_id;

  return jsonb_build_object('ok',true,'id',v_id,'costoUsd',v_costo,'sinTarifa',(t.id is null));
exception when others then
  return jsonb_build_object('ok',false,'error',sqlerrm);
end $fn$;

grant execute on function mos.ia_registrar_uso(jsonb) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) LO QUE VE EL PANEL: agrupado por día, y dentro de cada día por función,
--    por app y por modelo. Todo en una sola llamada.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos.ia_uso_resumen(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_dias int  := greatest(1, least(180, coalesce((p->>'dias')::int, 30)));
  v_hoy  date := (now() at time zone 'America/Lima')::date;
  v_desde date := v_hoy - (v_dias - 1);
  v_dias_j jsonb; v_tot jsonb; v_fun jsonb; v_mod jsonb; v_app jsonb; v_sin int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- fila por día, con su desglose adentro
  select coalesce(jsonb_agg(x.obj order by x.dia desc), '[]'::jsonb) into v_dias_j
    from (
      select u.dia, jsonb_build_object(
        'dia',       to_char(u.dia,'YYYY-MM-DD'),
        'llamadas',  count(*),
        'tokIn',     sum(u.tok_in), 'tokOut', sum(u.tok_out),
        'tokCacheW', sum(u.tok_cache_w), 'tokCacheR', sum(u.tok_cache_r),
        'tokens',    sum(u.tok_in + u.tok_out + u.tok_cache_w + u.tok_cache_r),
        'usd',       round(coalesce(sum(u.costo_usd),0), 4),
        'errores',   count(*) filter (where not u.ok),
        'funciones', (select coalesce(jsonb_agg(f.o order by (f.o->>'usd')::numeric desc), '[]'::jsonb)
                        from (select jsonb_build_object(
                                'funcion', u2.funcion, 'app', min(u2.app), 'llamadas', count(*),
                                'tokIn', sum(u2.tok_in), 'tokOut', sum(u2.tok_out),
                                'tokens', sum(u2.tok_in+u2.tok_out+u2.tok_cache_w+u2.tok_cache_r),
                                'usd', round(coalesce(sum(u2.costo_usd),0),4),
                                'errores', count(*) filter (where not u2.ok),
                                'modelos', (select string_agg(distinct coalesce(u3.etiqueta, u3.modelo), ' · ')
                                              from mos.ia_uso u3
                                             where u3.dia = u2.dia and u3.funcion = u2.funcion)
                              ) o
                         from mos.ia_uso u2 where u2.dia = u.dia group by u2.dia, u2.funcion) f)
      ) obj
      from mos.ia_uso u
     where u.dia between v_desde and v_hoy
     group by u.dia
    ) x;

  -- totales del período + rankings
  select jsonb_build_object(
      'llamadas', count(*), 'usd', round(coalesce(sum(costo_usd),0),4),
      'tokens', coalesce(sum(tok_in+tok_out+tok_cache_w+tok_cache_r),0),
      'tokIn', coalesce(sum(tok_in),0), 'tokOut', coalesce(sum(tok_out),0),
      'tokCacheR', coalesce(sum(tok_cache_r),0),
      'errores', count(*) filter (where not ok),
      'usdHoy', round(coalesce(sum(costo_usd) filter (where dia = v_hoy),0),4),
      'usdMes', round(coalesce((select sum(costo_usd) from mos.ia_uso
                                 where dia >= date_trunc('month', v_hoy)::date),0),4),
      'promDia', round(coalesce(sum(costo_usd),0) / greatest(1, count(distinct dia)), 4))
    into v_tot from mos.ia_uso where dia between v_desde and v_hoy;

  select coalesce(jsonb_agg(o order by (o->>'usd')::numeric desc), '[]'::jsonb) into v_fun from (
    select jsonb_build_object('funcion', funcion, 'llamadas', count(*),
             'usd', round(coalesce(sum(costo_usd),0),4),
             'tokens', sum(tok_in+tok_out+tok_cache_w+tok_cache_r),
             'usdPorLlamada', round(coalesce(sum(costo_usd),0)/greatest(1,count(*)),6)) o
      from mos.ia_uso where dia between v_desde and v_hoy group by funcion) q;

  select coalesce(jsonb_agg(o order by (o->>'usd')::numeric desc), '[]'::jsonb) into v_mod from (
    select jsonb_build_object('modelo', coalesce(etiqueta, modelo), 'id', min(modelo),
             'llamadas', count(*), 'usd', round(coalesce(sum(costo_usd),0),4),
             'tokens', sum(tok_in+tok_out+tok_cache_w+tok_cache_r)) o
      from mos.ia_uso where dia between v_desde and v_hoy group by coalesce(etiqueta, modelo)) q;

  select coalesce(jsonb_agg(o order by (o->>'usd')::numeric desc), '[]'::jsonb) into v_app from (
    select jsonb_build_object('app', app, 'llamadas', count(*),
             'usd', round(coalesce(sum(costo_usd),0),4)) o
      from mos.ia_uso where dia between v_desde and v_hoy group by app) q;

  select count(*) into v_sin from mos.ia_uso where sin_tarifa and dia between v_desde and v_hoy;

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'desde', to_char(v_desde,'YYYY-MM-DD'), 'hasta', to_char(v_hoy,'YYYY-MM-DD'), 'dias', v_dias,
    'total', v_tot, 'porDia', v_dias_j, 'porFuncion', v_fun, 'porModelo', v_mod, 'porApp', v_app,
    'sinTarifa', v_sin,
    'tarifas', (select coalesce(jsonb_agg(jsonb_build_object(
                  'etiqueta', etiqueta, 'patron', patron, 'usdIn', usd_in, 'usdOut', usd_out,
                  'usdCacheR', usd_cache_r) order by etiqueta), '[]'::jsonb) from mos.ia_precios),
    'primerRegistro', (select to_char(min(dia),'YYYY-MM-DD') from mos.ia_uso)));
end $fn$;

grant execute on function mos.ia_uso_resumen(jsonb) to anon, authenticated, service_role;

commit;
