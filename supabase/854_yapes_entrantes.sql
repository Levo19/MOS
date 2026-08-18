-- 854_yapes_entrantes.sql — CAPTURA Y VERIFICACIÓN DE YAPES
--
-- [DUEÑO] "quiero capturar los Yapes que entran a un celular, guardarlos en una tabla y matchearlos
--  con las cajas abiertas. El cliente paga S/5 por Yape, el cajero emite el ticket como VIRTUAL de
--  S/5; un programa captura la notificación, la guarda, MosExpress lo dice en voz alta ('5 soles de
--  Cintia') y el ticket queda VERIFICADO. En el cierre de caja se ve cuáles se verificaron y cuáles
--  no. Porque pueden entrar dos clientes seguidos de S/5 y uno pagar y el otro no."
--
-- EL PUNTO ES *VERIFICAR*, NO ADIVINAR. Por eso las reglas son deliberadamente conservadoras:
--   · un Yape verifica COMO MÁXIMO un ticket, y un ticket lo verifica COMO MÁXIMO un Yape (1 a 1)
--   · si para un Yape hay DOS tickets candidatos del mismo monto, NO se elige ninguno: queda
--     AMBIGUO para que una persona decida. Elegir "el más cercano en tiempo" sería exactamente el
--     error que el dueño quiere evitar: marcar como pagado al que no pagó.
--   · un ticket sin Yape NO es un ticket malo: puede ser que el Yape aún no llegue. Se dice
--     "sin verificar", nunca "no pagado".
--
-- El texto CRUDO de la notificación se guarda SIEMPRE, aunque el parseo falle: sin él no hay forma
-- de arreglar el parser cuando Yape cambie el formato de sus mensajes.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) LOS CELULARES AUTORIZADOS. Cada uno con su secreto propio, revocable, y la
--    zona a la que pertenece — así un Yape solo puede verificar tickets de SU zona.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists mos.yape_dispositivos (
  id            bigserial primary key,
  nombre        text not null,
  zona          text,                          -- null = puede verificar cualquier zona
  secreto_hash  text not null,                 -- sha256 del secreto que lleva el APK
  activo        boolean not null default true,
  ultima_señal  timestamptz,
  n_capturas    bigint not null default 0,
  creado_ts     timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) LOS YAPES CAPTURADOS.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists mos.yapes_entrantes (
  id             bigserial primary key,
  notif_key      text not null,                -- clave estable de la notificación (anti duplicado)
  ts_notificacion timestamptz not null,        -- cuándo la mostró el celular
  ts_recibido    timestamptz not null default now(),
  dia            date not null default ((now() at time zone 'America/Lima')::date),
  monto          numeric(12,2),
  pagador        text,
  raw            text not null,                -- SIEMPRE, aunque el parseo falle
  paquete        text,
  dispositivo    text,                         -- nombre del celular que la capturó
  zona           text,
  estado         text not null default 'NUEVO',-- NUEVO · MATCHEADO · AMBIGUO · DESCARTADO
  id_venta       text,                         -- ticket verificado por este Yape
  match_ts       timestamptz,
  match_por      text,                         -- 'AUTO' o el nombre de quien lo resolvió a mano
  anunciado      boolean not null default false,
  meta           jsonb not null default '{}'::jsonb
);
create unique index if not exists ux_yapes_notif on mos.yapes_entrantes (notif_key);
create unique index if not exists ux_yapes_venta on mos.yapes_entrantes (id_venta) where id_venta is not null;
create index if not exists ix_yapes_dia on mos.yapes_entrantes (dia desc, estado);
create index if not exists ix_yapes_pend on mos.yapes_entrantes (estado, ts_notificacion desc) where estado in ('NUEVO','AMBIGUO');
alter table mos.yapes_entrantes enable row level security;
alter table mos.yape_dispositivos enable row level security;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) EL PARSER. Yape cambia el texto de sus notificaciones cada tanto, así que
--    se prueban varias formas y, si ninguna calza, la fila igual se guarda con el
--    texto crudo y monto null: se ve en el panel y se arregla el patrón, sin perder
--    el dato. Nunca se descarta una notificación por no entenderla.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos._yape_parse(p_texto text)
returns jsonb language plpgsql immutable set search_path to '' as $fn$
declare
  t text := regexp_replace(coalesce(p_texto,''), '[[:space:]]+', ' ', 'g');
  m text[]; v_monto numeric; v_nom text;
begin
  -- monto: "S/ 5", "S/5.00", "S/. 5,50"
  m := regexp_match(t, 'S/\.?[[:space:]]*([0-9]+(?:[.,][0-9]{1,2})?)');
  if m is not null then
    begin v_monto := replace(m[1], ',', '.')::numeric; exception when others then v_monto := null; end;
  end if;

  -- pagador: las formas que usa Yape en Perú
  --   "…recibiste un pago de S/ 5.00 de JUAN PEREZ"      → de <nombre> al final
  --   "JUAN PEREZ te envió S/ 5.00"                       → <nombre> te envió
  --   "Confirmación de Yape! JUAN P. te ha yapeado S/5"   → <nombre> te ha yapeado
  m := regexp_match(t, '(?:^|[!¡.:] ?)([A-ZÁÉÍÓÚÑ][^!¡.:]{1,60}?) te (?:envió|envio|ha yapeado|yapeó|yapeo)');
  if m is not null then v_nom := btrim(m[1]); end if;
  if v_nom is null then
    m := regexp_match(t, ' de ([A-ZÁÉÍÓÚÑ][A-Za-zÁÉÍÓÚÑáéíóúñ. ]{1,60}?)[[:space:]]*(?:$|[.!¡,]|por |el |a las )');
    if m is not null then v_nom := btrim(m[1]); end if;
  end if;
  if v_nom is not null then
    v_nom := btrim(regexp_replace(v_nom, '^(el|la|los|las|sr\.?|sra\.?)[[:space:]]+', '', 'i'));
    if length(v_nom) < 2 then v_nom := null; end if;
  end if;

  return jsonb_build_object('monto', v_monto, 'pagador', v_nom,
                            'ok', (v_monto is not null));
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) INGESTA desde el celular. Autenticada por secreto de dispositivo (revocable),
--    idempotente por notif_key: si el Android reenvía la misma notificación —cosa
--    normal, la reintenta hasta confirmar— no se duplica el cobro.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos.yape_ingesta(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_sec  text := coalesce(p->>'secreto','');
  v_dev  record;
  v_key  text := nullif(btrim(coalesce(p->>'notifKey','')),'');
  v_raw  text := coalesce(p->>'texto','');
  v_ts   timestamptz;
  v_par  jsonb; v_id bigint; v_nuevo boolean := true;
begin
  if v_sec = '' or v_key is null or btrim(v_raw) = '' then
    return jsonb_build_object('ok',false,'error','faltan secreto, notifKey o texto');
  end if;
  select * into v_dev from mos.yape_dispositivos
   where activo and secreto_hash = encode(digest(v_sec,'sha256'),'hex') limit 1;
  if not found then return jsonb_build_object('ok',false,'error','DISPOSITIVO_NO_AUTORIZADO'); end if;

  begin v_ts := (p->>'ts')::timestamptz; exception when others then v_ts := now(); end;
  v_ts := coalesce(v_ts, now());
  v_par := mos._yape_parse(v_raw);

  insert into mos.yapes_entrantes (notif_key, ts_notificacion, dia, monto, pagador, raw, paquete,
                                   dispositivo, zona, meta)
  values (v_key, v_ts, (v_ts at time zone 'America/Lima')::date,
          nullif(v_par->>'monto','')::numeric, nullif(v_par->>'pagador',''), v_raw,
          nullif(btrim(coalesce(p->>'paquete','')),''), v_dev.nombre, v_dev.zona,
          jsonb_build_object('titulo', coalesce(p->>'titulo',''), 'parseOk', (v_par->>'ok')::boolean))
  on conflict (notif_key) do nothing
  returning id into v_id;

  if v_id is null then
    v_nuevo := false;
    select id into v_id from mos.yapes_entrantes where notif_key = v_key;
  else
    update mos.yape_dispositivos set ultima_señal = now(), n_capturas = n_capturas + 1 where id = v_dev.id;
  end if;

  -- intentar casarlo con un ticket ya emitido (si el ticket llega después, lo agarra el cron)
  if v_nuevo then perform mos.yape_matchear(jsonb_build_object('id', v_id)); end if;

  return jsonb_build_object('ok',true,'id',v_id,'nuevo',v_nuevo,
    'monto', v_par->>'monto', 'pagador', v_par->>'pagador', 'parseOk', (v_par->>'ok')::boolean);
end $fn$;

grant execute on function mos.yape_ingesta(jsonb) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) EL MATCHEO. Conservador a propósito (ver cabecera).
--    Ventana: el Yape puede llegar antes o después de que el cajero emita el ticket.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos.yape_matchear(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_uno   bigint := nullif(p->>'id','')::bigint;
  v_min   int    := greatest(2, least(180, coalesce((p->>'ventanaMin')::int, 25)));
  y       record; v_cands int; v_venta text;
  v_match int := 0; v_amb int := 0;
begin
  for y in
    select * from mos.yapes_entrantes
     where estado in ('NUEVO','AMBIGUO')
       and monto is not null and monto > 0
       and (v_uno is null or id = v_uno)
       and ts_notificacion > now() - interval '2 days'
     order by ts_notificacion
  loop
    -- candidatos: ticket VIRTUAL vivo, mismo monto exacto, misma ventana de tiempo,
    -- de la zona del celular (si el celular tiene zona), y todavía sin Yape asignado.
    select count(*), min(v.id_venta) into v_cands, v_venta
      from me.ventas v
     where upper(coalesce(v.forma_pago,'')) = 'VIRTUAL'
       and abs(coalesce(v.total,0) - y.monto) < 0.005
       and v.fecha between y.ts_notificacion - make_interval(mins => v_min)
                       and y.ts_notificacion + make_interval(mins => v_min)
       and (coalesce(y.zona,'') = '' or upper(btrim(coalesce(v.zona,''))) = upper(btrim(y.zona)))
       and not exists (select 1 from mos.yapes_entrantes y2
                        where y2.id_venta = v.id_venta and y2.id <> y.id);

    if v_cands = 1 then
      update mos.yapes_entrantes
         set estado='MATCHEADO', id_venta=v_venta, match_ts=now(), match_por='AUTO'
       where id = y.id;
      v_match := v_match + 1;
    elsif v_cands > 1 then
      -- DOS tickets iguales y un solo Yape: no se adivina. Queda para que alguien resuelva.
      update mos.yapes_entrantes set estado='AMBIGUO',
             meta = meta || jsonb_build_object('candidatos', v_cands)
       where id = y.id and estado <> 'AMBIGUO';
      v_amb := v_amb + 1;
    end if;
  end loop;

  return jsonb_build_object('ok',true,'matcheados',v_match,'ambiguos',v_amb);
end $fn$;

grant execute on function mos.yape_matchear(jsonb) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6) LO QUE LEE MOSEXPRESS: los Yapes que todavía no se cantaron en voz alta.
--    Se marcan como anunciados en la misma llamada → nunca se repite el mismo aviso.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos.yape_pendientes_anuncio(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_zona text := nullif(btrim(coalesce(p->>'zona','')),''); v_out jsonb;
begin
  with pend as (
    select id, monto, pagador, estado, id_venta, raw,
           to_char(ts_notificacion at time zone 'America/Lima','HH24:MI') hora
      from mos.yapes_entrantes
     where not anunciado
       and ts_notificacion > now() - interval '30 minutes'
       and (v_zona is null or coalesce(zona,'') = '' or upper(btrim(zona)) = upper(v_zona))
     order by ts_notificacion
     limit 20
  ), marca as (
    update mos.yapes_entrantes set anunciado = true where id in (select id from pend) returning id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'monto', monto, 'pagador', coalesce(pagador,''), 'hora', hora,
           'estado', estado, 'idVenta', coalesce(id_venta,''),
           'frase', case when monto is null then 'Llegó un Yape que no pude leer'
                         else trim(to_char(monto,'FM999990.99')) || ' soles' ||
                              case when coalesce(pagador,'') <> '' then ' de ' || pagador else '' end end
         ) order by id), '[]'::jsonb) into v_out
    from pend, (select count(*) from marca) _;

  return jsonb_build_object('ok',true,'data', jsonb_build_object('yapes', v_out));
end $fn$;

grant execute on function mos.yape_pendientes_anuncio(jsonb) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7) El cron que reintenta: un Yape puede llegar ANTES de que el cajero emita el
--    ticket. Cada 2 minutos vuelve a probar los que quedaron sin casar.
-- ─────────────────────────────────────────────────────────────────────────────
select cron.schedule('yape-matchear', '*/2 * * * *', $cron$ select mos.yape_matchear('{}'::jsonb) $cron$)
where not exists (select 1 from cron.job where jobname = 'yape-matchear');

commit;
