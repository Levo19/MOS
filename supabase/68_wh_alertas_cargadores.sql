-- 68_wh_alertas_cargadores.sql — [Tanda 3] Escritura directa: ALERTAS DE STOCK + CARGADORES DEL DÍA. INERTE.
-- 4 RPCs, cada una gateada por su propio flag mos.config.WH_*_DIRECTO (default '0'). Ninguna corre hasta flipear.
-- Réplica fiel de:
--   · marcarAlertaRevisada  (Auditoria.gs) → marca la alerta revisada. NO toca stock. Idempotente natural.
--   · aceptarTeoricoAlerta  (Auditoria.gs) → corrección one-click: crea AJUSTE para que stock real → teórico + marca
--                                            revisada. SÍ TOCA STOCK (vía crearAjuste). DEDUP por local_id.
--   · addCargadorDia        (Cargadores.gs) → +1 cargador del día (append a CARGADORES_LOG). NO toca stock. DEDUP.
--   · removeCargadorDia     (Cargadores.gs) → -1 (marca el row ACTIVO más reciente como ELIMINADO). NO toca stock. DEDUP.
--
-- TABLAS DESTINO en la sombra wh.* (verificadas en 03_schema_wh.sql):
--   · wh.alertas_stock (id_alerta pk, cod_producto, stock_real, stock_teorico, diferencia, revisado BOOLEAN, fecha_revision)
--       ⚠️ OJO: en la sombra `revisado` es BOOLEAN (no 'SI'/'NO' como el Sheet) → escribimos `true`.
--   · wh.cargadores_log (id_log pk, fecha, id_cargador, nombre, added_by, device_id, ts, estado)
--   · (aceptarTeoricoAlerta) reusa wh.stock / wh.ajustes / wh.stock_movimientos con el MISMO patrón atómico de wh.crear_ajuste (30).

insert into mos.config (clave, valor, descripcion) values
  ('WH_MARCAR_ALERTA_REVISADA_DIRECTO','0','WH: marcar alerta de stock como revisada directo (RPC wh.marcar_alerta_revisada). NO toca stock.'),
  ('WH_ACEPTAR_TEORICO_ALERTA_DIRECTO','0','WH: aceptar teorico de alerta directo (RPC wh.aceptar_teorico_alerta). CREA AJUSTE -> TOCA STOCK. Validar antes de prender.'),
  ('WH_ADD_CARGADOR_DIA_DIRECTO','0','WH: agregar cargador al dia directo (RPC wh.add_cargador_dia). NO toca stock.'),
  ('WH_REMOVE_CARGADOR_DIA_DIRECTO','0','WH: quitar cargador del dia directo (RPC wh.remove_cargador_dia). NO toca stock.')
on conflict (clave) do nothing;

-- ════════════════════════════════════════════════════════════════════════════════════
-- 1. marcar_alerta_revisada — marca una alerta de stock como revisada (réplica marcarAlertaRevisada).
--   · NO toca stock. Solo set revisado=true + fecha_revision=now() en la fila por id_alerta.
--   · Idempotencia NATURAL: re-aplicar el mismo UPDATE a un valor concreto da el mismo resultado (no efectos por delta).
--     Por eso NO necesita dedup por local_id. El GAS devuelve {ok:true} sin payload extra; espejamos eso.
-- p = { id_alerta }
create or replace function wh.marcar_alerta_revisada(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'id_alerta','')), '');
  v_n  int;
begin
  if coalesce((select valor from mos.config where clave='WH_MARCAR_ALERTA_REVISADA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_MARCAR_ALERTA_REVISADA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  update wh.alertas_stock set revisado = true, fecha_revision = now() where id_alerta = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','ALERTA_NO_ENCONTRADA'); end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

revoke all on function wh.marcar_alerta_revisada(jsonb) from public;
grant execute on function wh.marcar_alerta_revisada(jsonb) to service_role, authenticated;

-- ════════════════════════════════════════════════════════════════════════════════════
-- 2. aceptar_teorico_alerta — corrección one-click (réplica aceptarTeoricoAlerta).
--   · Lee stock_real / stock_teorico FROM la fila de la alerta (server-side source of truth, igual que el GAS, que toma
--     esos valores de la propia hoja ALERTAS_STOCK — NO recalcula contra wh.stock).
--   · diff = teorico - real (ajuste para que real → teorico). Si |diff| <= 0.5 → SOLO marca revisada (no crea ajuste),
--     igual que el GAS (return ajusteAplicado:0). Si |diff| > 0.5 → crea AJUSTE INC/DEC y MUEVE STOCK atómicamente.
--   · TOCA STOCK por DELTA → NO idempotente natural → DEDUP por wh._dedup_nuevo(local_id) + id_ajuste determinista.
--       - El guard de dedup cubre el reintento del MISMO POST (doble-tap/timeout con el mismo local_id).
--       - El FOR UPDATE sobre la fila de alerta serializa contra dos aceptaciones concurrentes de la MISMA alerta.
--       - El guard `revisado` (chequeado JUSTO tras el SELECT ... FOR UPDATE) hace la idempotencia POR-ALERTA: si
--         dos doble-taps generan local_id DISTINTOS, ambos pasan _dedup_nuevo pero solo el 1ro mueve stock; el 2do
--         ve revisado=true y hace early-return sin crear ajuste ni mover stock. Defensa adicional: id_ajuste
--         determinista (AJ_<local_id>) + `on conflict (id_ajuste) do nothing`.
--   · Stock: UPDATE ATÓMICO (cantidad = cantidad + delta) sobre la 1ra fila por id_stock del producto — JAMÁS
--     read-modify-write. Espeja EXACTAMENTE wh.crear_ajuste (30) + _actualizarStock del GAS (tipo AJUSTE_MANUAL).
--   · local_id OBLIGATORIO cuando hay ajuste (mueve stock por delta sin idempotencia natural).
-- p = { id_alerta, usuario?, id_ajuste?, id_stock_nuevo?, id_mov?, local_id (OBLIGATORIO) }
create or replace function wh.aceptar_teorico_alerta(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id      text := nullif(btrim(coalesce(p->>'id_alerta','')), '');
  v_usuario text := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'sistema');
  v_idaj    text := nullif(btrim(coalesce(p->>'id_ajuste','')), '');
  v_idstk   text := nullif(btrim(coalesce(p->>'id_stock_nuevo','')), '');
  v_idmov   text := nullif(btrim(coalesce(p->>'id_mov','')), '');
  v_lid     text := nullif(btrim(coalesce(p->>'local_id','')), '');
  v_cod     text; v_real numeric; v_teor numeric; v_diff numeric;
  v_tipo    text; v_cant numeric; v_delta numeric; v_antes numeric; v_despues numeric;
  v_aj      text; v_revisado boolean;
begin
  if coalesce((select valor from mos.config where clave='WH_ACEPTAR_TEORICO_ALERTA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ACEPTAR_TEORICO_ALERTA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  -- [dedup] crea ajuste (mueve stock por delta) → NO idempotente natural → si este local_id ya se procesó, early-return.
  if v_lid is not null and not wh._dedup_nuevo(v_lid, 'aceptar_teorico_alerta') then
    return jsonb_build_object('ok',true,'dedup',true,'id_alerta',v_id);
  end if;
  -- mueve stock por DELTA sin idempotencia natural; sin local_id el dedup se saltaría → exigirlo (igual que crear_ajuste/auditar).
  if v_lid is null then return jsonb_build_object('ok',false,'error','FALTA_LOCAL_ID'); end if;

  -- localizar + BLOQUEAR la alerta (FOR UPDATE serializa contra aceptación concurrente de la misma alerta)
  select coalesce(cod_producto,''), coalesce(stock_real,0), coalesce(stock_teorico,0), coalesce(revisado,false)
    into v_cod, v_real, v_teor, v_revisado
    from wh.alertas_stock where id_alerta = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','ALERTA_NO_ENCONTRADA'); end if;
  -- [idempotencia por-alerta] si dos doble-taps generan local_id DISTINTOS, ambos pasan el _dedup_nuevo
  -- y moverían el stock DOS veces. El guard `revisado` (bajo el FOR UPDATE) garantiza que una alerta solo
  -- se ajusta UNA vez: si ya está revisada, early-return idempotente SIN crear ajuste ni mover stock.
  if v_revisado then return jsonb_build_object('ok',true,'dedup',true,'id_alerta',v_id,'ajusteAplicado',0); end if;

  v_diff := v_teor - v_real;   -- ajuste para que real → teórico

  -- |diff| <= 0.5 → ya están iguales; solo marcar revisada (paridad con GAS: ajusteAplicado:0)
  if abs(v_diff) <= 0.5 or v_cod = '' then
    update wh.alertas_stock set revisado = true, fecha_revision = now() where id_alerta = v_id;
    return jsonb_build_object('ok',true,'dedup',false,'id_alerta',v_id,'ajusteAplicado',0);
  end if;

  -- crear AJUSTE INC/DEC para corregir + mover stock (réplica crear_ajuste/_actualizarStock; tipo AJUSTE_MANUAL)
  v_tipo  := case when v_diff > 0 then 'INC' else 'DEC' end;
  v_cant  := abs(v_diff);
  v_delta := v_diff;   -- INC:+ / DEC:- (delta = teorico - real, directo)
  v_aj    := coalesce(v_idaj, 'AJ_'||v_lid);   -- id_ajuste determinista → idempotente ante reintento (on conflict do nothing)

  update wh.stock set cantidad_disponible = cantidad_disponible + v_delta, ultima_actualizacion = now()
   where id_stock = (select id_stock from wh.stock where cod_producto = v_cod order by id_stock limit 1)
   returning cantidad_disponible into v_despues;
  if found then
    v_antes := v_despues - v_delta;
  else
    v_antes := 0; v_despues := v_delta;
    insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
    values (coalesce(v_idstk, 'STK_'||v_lid), v_cod, v_despues, now());
  end if;

  insert into wh.ajustes (id_ajuste, cod_producto, tipo_ajuste, cantidad_ajuste, motivo, usuario, id_auditoria, fecha)
  values (v_aj, v_cod, v_tipo, v_cant, 'Aceptar teórico (alerta cuadre stock)', v_usuario, '', now())
  on conflict (id_ajuste) do nothing;

  if v_idmov is not null then
    insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
    values (v_idmov, now(), v_cod, v_delta, v_antes, v_despues, 'AJUSTE_MANUAL', v_aj, v_usuario)
    on conflict (id_mov) do nothing;
  end if;

  -- marcar la alerta revisada
  update wh.alertas_stock set revisado = true, fecha_revision = now() where id_alerta = v_id;

  return jsonb_build_object('ok',true,'dedup',false,'id_alerta',v_id,'ajusteAplicado',v_diff,'idAjuste',v_aj,
    'stockAntes',v_antes,'stockNuevo',v_despues);
end;
$fn$;

revoke all on function wh.aceptar_teorico_alerta(jsonb) from public;
grant execute on function wh.aceptar_teorico_alerta(jsonb) to service_role, authenticated;

-- ════════════════════════════════════════════════════════════════════════════════════
-- 3. add_cargador_dia — +1 cargador del día (réplica addCargadorDia).
--   · NO toca stock. Inserta UNA fila en wh.cargadores_log (estado ACTIVO) y devuelve el conteo ACTIVO del día.
--   · El APPEND NO es idempotente natural (re-correr el mismo POST agregaría otro +1) → DEDUP por id_log determinista:
--     el cliente pasa id_log = 'CLG_'+local_id; `on conflict (id_log) do nothing` colapsa el reintento del mismo POST.
--   · fecha es text yyyy-MM-dd en el GAS (formato día); acá la guardamos en la col timestamptz fecha anclada al día Lima.
--     El conteo agrupa por (id_cargador, día Lima de fecha) + estado ACTIVO — espeja _contarCargadorDia (substring(0,10)).
--   ⚠️ ANTES DE ACTIVAR WH_ADD_CARGADOR_DIA_DIRECTO (y _REMOVE_): VERIFICAR EN DATOS que las filas históricas de
--     wh.cargadores_log (sembradas por el dual-write GAS→sombra) tengan `fecha` ANCLADA A MEDIANOCHE LIMA. El conteo
--     agrupa por (fecha at time zone 'America/Lima')::date; si una fila histórica quedó con fecha en otra TZ/hora
--     (p.ej. medianoche UTC), al convertirla a día Lima cae al día anterior y el conteo se DESFASA en convivencia
--     (la RPC contaría/quitaría del día equivocado mezclando filas viejas con las nuevas). Esto es verificación de
--     DATOS, no de código. Query sugerida: select id_log,fecha,(fecha at time zone 'America/Lima') from wh.cargadores_log limit 50;
-- p = { id_cargador, fecha?, nombre?, usuario?, device_id?, id_log }
create or replace function wh.add_cargador_dia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idc    text := nullif(btrim(coalesce(p->>'id_cargador','')), '');
  v_fraw   text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_nombre text := coalesce(p->>'nombre','');
  v_user   text := coalesce(p->>'usuario','');
  v_dev    text := coalesce(p->>'device_id','');
  v_idlog  text := nullif(btrim(coalesce(p->>'id_log','')), '');
  -- día (yyyy-MM-dd): el que mande el front si es válido; sino hoy Lima. Se guarda como timestamptz a medianoche Lima.
  v_dia    date := case when v_fraw is not null and left(v_fraw,10) ~ '^\d{4}-\d{2}-\d{2}$'
                        then left(v_fraw,10)::date else (now() at time zone 'America/Lima')::date end;
  v_fecha  timestamptz := (v_dia::text || ' 00:00:00')::timestamp at time zone 'America/Lima';
  v_conteo int;
begin
  if coalesce((select valor from mos.config where clave='WH_ADD_CARGADOR_DIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ADD_CARGADOR_DIA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idc is null then return jsonb_build_object('ok',false,'error','idCargador requerido'); end if;
  -- append no idempotente natural → sin id_log determinista un reintento duplicaría el +1.
  if v_idlog is null then return jsonb_build_object('ok',false,'error','FALTA_ID_LOG'); end if;

  insert into wh.cargadores_log (id_log, fecha, id_cargador, nombre, added_by, device_id, ts, estado)
  values (v_idlog, v_fecha, v_idc, v_nombre, v_user, v_dev, now(), 'ACTIVO')
  on conflict (id_log) do nothing;

  select count(*) into v_conteo from wh.cargadores_log
   where id_cargador = v_idc and upper(coalesce(estado,'')) = 'ACTIVO'
     and (fecha at time zone 'America/Lima')::date = v_dia;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idLog',v_idlog,'conteo',v_conteo,'fecha',to_char(v_dia,'YYYY-MM-DD')));
end;
$fn$;

revoke all on function wh.add_cargador_dia(jsonb) from public;
grant execute on function wh.add_cargador_dia(jsonb) to service_role, authenticated;

-- ════════════════════════════════════════════════════════════════════════════════════
-- 4. remove_cargador_dia — -1 cargador del día (réplica removeCargadorDia).
--   · NO toca stock. Marca el row ACTIVO MÁS RECIENTE (mayor ts) del cargador en ese día como ELIMINADO.
--   · Idempotencia: cada llamada exitosa baja el conteo en 1 (es un -1 real, no un set a valor fijo). Un reintento del
--     MISMO POST (timeout/doble-tap) NO debe quitar DOS → DEDUP por wh._dedup_nuevo(local_id). El `... limit 1 for update`
--     bloquea la fila elegida y serializa contra removes concurrentes (cada uno toma un row ACTIVO distinto).
--   · local_id OBLIGATORIO (sin él el dedup se salta y un reintento quitaría de más).
-- p = { id_cargador, fecha?, local_id (OBLIGATORIO) }
create or replace function wh.remove_cargador_dia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idc   text := nullif(btrim(coalesce(p->>'id_cargador','')), '');
  v_fraw  text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_lid   text := nullif(btrim(coalesce(p->>'local_id','')), '');
  v_dia   date := case when v_fraw is not null and left(v_fraw,10) ~ '^\d{4}-\d{2}-\d{2}$'
                       then left(v_fraw,10)::date else (now() at time zone 'America/Lima')::date end;
  v_best  text;
  v_conteo int;
begin
  if coalesce((select valor from mos.config where clave='WH_REMOVE_CARGADOR_DIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_REMOVE_CARGADOR_DIA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idc is null then return jsonb_build_object('ok',false,'error','idCargador requerido'); end if;
  -- -1 real (no set a valor fijo) → reintento del mismo POST quitaría de más → dedup por local_id.
  if v_lid is not null and not wh._dedup_nuevo(v_lid, 'remove_cargador_dia') then
    -- ya se procesó: devolver el conteo actual sin volver a quitar
    select count(*) into v_conteo from wh.cargadores_log
     where id_cargador = v_idc and upper(coalesce(estado,'')) = 'ACTIVO'
       and (fecha at time zone 'America/Lima')::date = v_dia;
    return jsonb_build_object('ok',true,'dedup',true,'data',jsonb_build_object('conteo',v_conteo,'fecha',to_char(v_dia,'YYYY-MM-DD')));
  end if;
  if v_lid is null then return jsonb_build_object('ok',false,'error','FALTA_LOCAL_ID'); end if;

  -- elegir + BLOQUEAR el row ACTIVO más reciente (mayor ts; igual que el GAS que toma el de mayor timestamp)
  select id_log into v_best from wh.cargadores_log
   where id_cargador = v_idc and upper(coalesce(estado,'')) = 'ACTIVO'
     and (fecha at time zone 'America/Lima')::date = v_dia
   order by ts desc nulls last, id_log desc limit 1 for update;
  if v_best is null then return jsonb_build_object('ok',false,'error','sin entradas ACTIVO para quitar'); end if;

  update wh.cargadores_log set estado = 'ELIMINADO' where id_log = v_best;

  select count(*) into v_conteo from wh.cargadores_log
   where id_cargador = v_idc and upper(coalesce(estado,'')) = 'ACTIVO'
     and (fecha at time zone 'America/Lima')::date = v_dia;
  return jsonb_build_object('ok',true,'dedup',false,'data',jsonb_build_object('conteo',v_conteo,'fecha',to_char(v_dia,'YYYY-MM-DD')));
end;
$fn$;

revoke all on function wh.remove_cargador_dia(jsonb) from public;
grant execute on function wh.remove_cargador_dia(jsonb) to service_role, authenticated;
