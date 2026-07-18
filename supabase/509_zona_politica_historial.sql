-- 509_zona_politica_historial.sql — POLÍTICA DE ZONA VERSIONADA POR FECHA (no retroactiva)
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- Problema: comisionExcedentePct / metaDiaria / metaAuditorias vivían SOLO como el valor ACTUAL en
-- mos.zonas.politica_json. Recalcular un día viejo (lápiz, recompute) usaba el % de HOY → RETROACTIVO.
-- Solución: historial (id_zona, campo, valor, vigente_desde). El valor para un día D = el registro con
-- mayor vigente_desde <= D. Cambiar el % en config aplica DESDE la fecha elegida (default hoy) hacia
-- adelante; los días anteriores conservan el valor que regía entonces. Se puede fijar una fecha de
-- vigencia anterior si el jefe quiere que aplique retroactivo a propósito.
--
-- Compatibilidad: _meta_zona(zona)/_comision_pct(zona) (1-arg) siguen existiendo = valor de HOY (otros
-- callers: ME 241, RIZ 128, no cambian). El recompute (289) pasa a la variante 2-arg con el día real.
-- DINERO: cero cambio de comportamiento para HOY (historial más reciente == politica_json actual).

create table if not exists mos.zona_politica_historial (
  id            bigint generated always as identity primary key,
  id_zona       text  not null,
  campo         text  not null,                 -- 'comisionExcedentePct' | 'metaDiaria' | 'metaAuditorias'
  valor         numeric not null,
  vigente_desde date  not null,
  ts_creado     timestamptz not null default now(),
  creado_por    text
);
create index if not exists ix_zpol_hist_lookup
  on mos.zona_politica_historial (upper(btrim(id_zona)), campo, vigente_desde desc, id desc);

-- valor vigente de un campo de política para un día dado (null si la zona no tiene historial de ese campo)
create or replace function mos._politica_valor(p_zona text, p_campo text, p_dia date)
returns numeric language sql stable set search_path = '' as $fn$
  select coalesce(
    -- 1) el registro vigente para ese día (mayor vigente_desde <= día)
    (select h.valor from mos.zona_politica_historial h
      where upper(btrim(h.id_zona)) = upper(btrim(p_zona)) and h.campo = p_campo
        and h.vigente_desde <= p_dia
      order by h.vigente_desde desc, h.id desc limit 1),
    -- 2) días anteriores al primer registro → el más antiguo (se asume que regía desde antes)
    (select h.valor from mos.zona_politica_historial h
      where upper(btrim(h.id_zona)) = upper(btrim(p_zona)) and h.campo = p_campo
      order by h.vigente_desde asc, h.id asc limit 1)
  );
$fn$;

-- 2-arg date-aware: historial → politica_json actual → config global → 0 (misma cascada que la 1-arg)
create or replace function mos._meta_zona(p_zona text, p_dia date)
returns numeric language sql stable set search_path = '' as $fn$
  select coalesce(
    mos._politica_valor(p_zona, 'metaDiaria', p_dia),
    mos._numn((select politica_json->>'metaDiaria' from mos.zonas where upper(btrim(id_zona)) = upper(btrim(p_zona)) limit 1)),
    mos._numn((select valor from mos.config where clave='evalMetaCajero' limit 1)),
    0::numeric);
$fn$;
create or replace function mos._comision_pct(p_zona text, p_dia date)
returns numeric language sql stable set search_path = '' as $fn$
  select coalesce(
    mos._politica_valor(p_zona, 'comisionExcedentePct', p_dia),
    mos._numn((select politica_json->>'comisionExcedentePct' from mos.zonas where upper(btrim(id_zona)) = upper(btrim(p_zona)) limit 1)),
    mos._numn((select valor from mos.config where clave='evalComisionExcedentePct' limit 1)),
    0::numeric);
$fn$;

-- NOTA: las 1-arg _meta_zona(zona)/_comision_pct(zona) las sigue definiendo 289 (valor de HOY, directo
-- de politica_json) para los callers live (ME 241, RIZ 128). Para HOY, 1-arg == 2-arg(today) porque el
-- historial más reciente == politica_json actual. Solo el recompute (289) usa la 2-arg con el día real.

revoke all on function mos._politica_valor(text,text,date) from public;
revoke all on function mos._meta_zona(text,date)    from public;
revoke all on function mos._comision_pct(text,date) from public;
grant execute on function mos._politica_valor(text,text,date) to service_role;
grant execute on function mos._meta_zona(text,date)    to service_role;
grant execute on function mos._comision_pct(text,date) to service_role;

-- ── registrar un cambio de política con fecha de vigencia ────────────────────────────────────────────
-- Semilla: la 1ra vez que un campo cambia, se registra el valor ANTERIOR como vigente desde 2000-01-01
-- (así los días viejos NO heredan el valor nuevo). Luego inserta el valor nuevo con la fecha elegida.
create or replace function mos._zona_politica_registrar(
  p_zona text, p_campo text, p_valor_nuevo numeric, p_vigente date, p_por text)
returns void language plpgsql set search_path = '' as $fn$
declare v_actual numeric; v_hay boolean; v_seed numeric;
begin
  if p_valor_nuevo is null then return; end if;
  v_actual := mos._numn((select politica_json->>p_campo from mos.zonas where upper(btrim(id_zona))=upper(btrim(p_zona)) limit 1));
  if v_actual is not distinct from p_valor_nuevo then return; end if;   -- sin cambio real
  select exists(select 1 from mos.zona_politica_historial
                 where upper(btrim(id_zona))=upper(btrim(p_zona)) and campo=p_campo) into v_hay;
  -- semilla del valor que REGÍA antes (vigente "desde siempre") la 1ra vez, para que los días viejos NO
  -- hereden el valor nuevo. Si la zona no tenía valor propio, se siembra el default global de config (que
  -- es lo que el recompute usaba para esos días) → estrictamente no retroactivo incluso en la 1ra config.
  if not v_hay then
    v_seed := coalesce(v_actual, case p_campo
                when 'comisionExcedentePct' then mos._numn((select valor from mos.config where clave='evalComisionExcedentePct' limit 1))
                when 'metaDiaria'           then mos._numn((select valor from mos.config where clave='evalMetaCajero' limit 1))
                else null end);
    if v_seed is not null then
      insert into mos.zona_politica_historial(id_zona,campo,valor,vigente_desde,creado_por)
      values (p_zona, p_campo, v_seed, date '2000-01-01', 'seed');
    end if;
  end if;
  insert into mos.zona_politica_historial(id_zona,campo,valor,vigente_desde,creado_por)
  values (p_zona, p_campo, p_valor_nuevo, p_vigente, p_por);
end; $fn$;
revoke all on function mos._zona_politica_registrar(text,text,numeric,date,text) from public;
grant execute on function mos._zona_politica_registrar(text,text,numeric,date,text) to service_role;

-- ── actualizar_zona: registra el historial ANTES de pisar politica_json ───────────────────────────────
create or replace function mos.actualizar_zona(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id  text := nullif(btrim(coalesce(p->>'idZona','')),''); v_n int;
  v_pol jsonb := p->'politicaJSON';
  v_vig date := coalesce(nullif(btrim(coalesce(p->>'politicaVigenteDesde','')),'')::date,
                         (now() at time zone 'America/Lima')::date);
  v_por text := nullif(btrim(coalesce(p->>'validadoPor','')),'');
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idZona requerido'); end if;

  -- versionar los 3 campos numéricos de política (antes de pisar politica_json)
  if v_pol is not null and jsonb_typeof(v_pol) = 'object' then
    perform mos._zona_politica_registrar(v_id, 'comisionExcedentePct', mos._numn(v_pol->>'comisionExcedentePct'), v_vig, v_por);
    perform mos._zona_politica_registrar(v_id, 'metaDiaria',           mos._numn(v_pol->>'metaDiaria'),           v_vig, v_por);
    perform mos._zona_politica_registrar(v_id, 'metaAuditorias',       mos._numn(v_pol->>'metaAuditorias'),       v_vig, v_por);
  end if;

  update mos.zonas set
    nombre       = coalesce(nullif(btrim(coalesce(p->>'nombre','')),''), nombre),
    descripcion  = coalesce(p->>'descripcion', descripcion),
    direccion    = coalesce(p->>'direccion', direccion),
    responsable  = coalesce(p->>'responsable', responsable),
    estado       = coalesce(nullif(btrim(coalesce(p->>'estado','')),'')::boolean, estado),
    politica_json= coalesce(v_pol, politica_json)
   where id_zona = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','zona no encontrada'); end if;
  return jsonb_build_object('ok',true);
end; $fn$;
revoke all on function mos.actualizar_zona(jsonb) from public;
grant execute on function mos.actualizar_zona(jsonb) to anon, authenticated, service_role;

-- lectura del historial para la UI de config (timeline por zona)
create or replace function mos.zona_politica_historial_listar(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select jsonb_build_object('ok', true, 'data', coalesce(jsonb_agg(x order by x_zona, x_campo, x_vig desc), '[]'::jsonb))
  from (
    select id_zona x_zona, campo x_campo, vigente_desde x_vig,
           jsonb_build_object('idZona',id_zona,'campo',campo,'valor',valor,
                              'vigenteDesde',to_char(vigente_desde,'YYYY-MM-DD'),
                              'creadoPor',coalesce(creado_por,''),'ts',ts_creado) x
    from mos.zona_politica_historial
    where (nullif(btrim(coalesce(p->>'idZona','')),'') is null
           or upper(btrim(id_zona)) = upper(btrim(p->>'idZona')))
  ) s;
$fn$;
revoke all on function mos.zona_politica_historial_listar(jsonb) from public;
grant execute on function mos.zona_politica_historial_listar(jsonb) to anon, authenticated, service_role;
