-- ════════════════════════════════════════════════════════════════════════════
-- 214 · Dedup ATÓMICO de impresión de ticket de guía (mata el 3x de raíz)
-- ════════════════════════════════════════════════════════════════════════════
-- El 3x: imprimirTicketGuia (GAS) dedupea por hoja+60s PERO sin lock → 3 llamadas
-- casi simultáneas leen "no impresa" antes de que la 1ra registre → 3 jobs.
-- Fix: reserva ATÓMICA en Supabase ANTES de imprimir. `FOR UPDATE` serializa las
-- llamadas paralelas → solo la 1ra obtiene primera=true. Ventana corta (12s) mata
-- la ráfaga del triple-tap/paralelo pero permite reimpresión legítima posterior.
-- El frontend llama esto antes del GAS; si primera=false → no imprime. fuerzaCopia
-- (copia manual explícita) NO pasa por acá. Fail-open: si la RPC falla, imprime igual.
-- ════════════════════════════════════════════════════════════════════════════

create table if not exists wh.ticket_print_dedup (
  id_guia    text primary key,
  ultimo_ts  timestamptz not null default now(),
  usuario    text default '',
  veces      int not null default 1
);

create or replace function wh.reservar_ticket(p jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  v_id  text := nullif(btrim(coalesce(p->>'id_guia', p->>'idGuia', '')), '');
  v_win int  := coalesce(nullif(btrim(coalesce(p->>'ventana_seg','')),'')::int, 12);
  v_prev timestamptz;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'REQUIERE_ID'); end if;

  select ultimo_ts into v_prev from wh.ticket_print_dedup where id_guia = v_id for update;
  if found and v_prev > now() - make_interval(secs => v_win) then
    -- ráfaga: ya se reservó hace <ventana → NO imprimir (es el 2do/3er disparo del 3x)
    update wh.ticket_print_dedup set veces = veces + 1 where id_guia = v_id;
    return jsonb_build_object('ok', true, 'primera', false,
      'haceSeg', round(extract(epoch from (now() - v_prev))));
  end if;
  -- 1ra (o reimpresión legítima tras la ventana) → reservar e imprimir
  insert into wh.ticket_print_dedup (id_guia, ultimo_ts, usuario, veces)
  values (v_id, now(), coalesce(p->>'usuario', ''), 1)
  on conflict (id_guia) do update set
    ultimo_ts = now(), usuario = excluded.usuario, veces = wh.ticket_print_dedup.veces + 1;
  return jsonb_build_object('ok', true, 'primera', true);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM);
end;
$fn$;

revoke all on function wh.reservar_ticket(jsonb) from public;
grant execute on function wh.reservar_ticket(jsonb) to service_role, authenticated;
