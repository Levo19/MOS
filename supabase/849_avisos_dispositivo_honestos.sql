-- 849_avisos_dispositivo_honestos.sql
--
-- [DUEÑO] "me llegan avisos de 'un dispositivo pide acceso, entra y acepta', pero en realidad es un
--  equipo nuevo o suspendido que SOLO SE ABRE. Recién ahí existen dos formas: A remota, B in situ.
--  Muchas veces lo activo in situ y el aviso llega como si alguien pidiera algo. Si es A, notificar
--  está bien. Si es B, debería decir: ADMIN JESÚS REACTIVÓ UN DISPOSITIVO."
--
-- DÓNDE ESTABA LA MENTIRA (tres avisos, dos mal):
--
--  1. `registrar_dispositivo` — corre SOLO porque un equipo nuevo ABRIÓ la app, sin que nadie toque
--     nada, y disparaba "🔓 Dispositivo nuevo pide acceso · aprueba o rechaza en el panel". Nadie
--     pidió: el equipo apenas se registró. Ese aviso MUERE. El equipo igual queda PENDIENTE y sale
--     en el buzón con su badge; el aviso llega si la persona elige el camino A.
--
--  2. `aprobar_dispositivo` — no distinguía QUIÉN ni DÓNDE: el mismo "✅ Dispositivo aprobado · ya
--     puede operar" para una aprobación in situ y para una del panel, y sin nombrar a la persona.
--     Ahora recibe `origen` y dice la verdad: "Jesús reactivó un equipo · in situ".
--
--  3. `solicitar_acceso_dispositivo` — este SÍ es una petición real (camino A) y se queda, pero
--     ahora distingue si el equipo es NUEVO o venía SUSPENDIDO, que no es lo mismo para el que lee.
--
-- Regla que queda: **solo el camino A pide algo; B informa.**

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) Abrir la app NO es pedir acceso: se retira ese aviso.
-- ─────────────────────────────────────────────────────────────────────────────
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'registrar_dispositivo';

  v_new := replace(v_def,
$old$  begin
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('roles', case when upper(coalesce(v_app,'')) in ('MOS','')
                     then jsonb_build_array('MASTER') else jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN') end),
      'titulo', '🔓 Dispositivo nuevo pide acceso',
      'cuerpo', coalesce(v_app,'app') || ' · ' || coalesce(nullif(v_nombre,''),'equipo') || ' · aprueba o rechaza en el panel',
      'data', jsonb_build_object('tipo','device_pendiente','deviceId',v_id)));
  exception when others then null; end;$old$,
$old$  -- [849] SIN AVISO. Registrarse es solo abrir la app: nadie pidió nada todavía. El equipo queda
  -- PENDIENTE y visible en el buzón con su badge; el aviso sale recién si la persona elige el
  -- camino A (solicitar_acceso_dispositivo). Si lo activan in situ (B), avisa aprobar_dispositivo.$old$);
  if v_new = v_def then raise exception '849: no se encontró el push de registrar_dispositivo'; end if;
  execute v_new;
end $mig$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) La petición remota (A) dice si el equipo es NUEVO o venía SUSPENDIDO.
-- ─────────────────────────────────────────────────────────────────────────────
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'solicitar_acceso_dispositivo';

  -- capturar el estado ANTERIOR antes del upsert que lo pisa
  v_new := replace(v_def,
    $old$  d mos.dispositivos%rowtype; v_age numeric; v_pend int;$old$,
    $old$  d mos.dispositivos%rowtype; v_age numeric; v_pend int; v_era text;$old$);
  if v_new = v_def then raise exception '849: no se encontró el declare de solicitar_acceso'; end if;
  v_def := v_new;

  v_new := replace(v_def,
    $old$  -- crear/refrescar la solicitud: misma fila/equipo, nuevo pendiente_desde (la anterior se reemplaza)$old$,
    $old$  -- [849] de dónde viene: un equipo que el sistema suspendió no es lo mismo que uno nuevo
  v_era := upper(coalesce(d.estado, ''));
  -- crear/refrescar la solicitud: misma fila/equipo, nuevo pendiente_desde (la anterior se reemplaza)$old$);
  if v_new = v_def then raise exception '849: no se encontró el comentario del upsert'; end if;
  v_def := v_new;

  v_new := replace(v_def,
$old$      'titulo', '🔓 Dispositivo pide acceso',
      'cuerpo', coalesce(nullif(v_app,''),'app') || ' · ' || coalesce(nullif(v_nombre,''),'equipo') || ' · aprueba en el panel',$old$,
$old$      'titulo', case when v_era in ('SUSPENDIDO','INACTIVO','CANCELADO_AUTO')
                    then '🔓 Piden REACTIVAR un equipo' else '🔓 Equipo NUEVO pide acceso' end,
      'cuerpo', coalesce(nullif(v_app,''),'app') || ' · ' || coalesce(nullif(v_nombre,''),'equipo') || ' · '
                || case when v_era in ('SUSPENDIDO','INACTIVO','CANCELADO_AUTO')
                        then 'lo pidieron a distancia — apruébalo en el panel'
                        else 'apruébalo o recházalo en el panel' end,$old$);
  if v_new = v_def then raise exception '849: no se encontró el push de solicitar_acceso'; end if;
  execute v_new;
end $mig$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) La aprobación dice QUIÉN y DÓNDE. In situ informa; el panel confirma.
-- ─────────────────────────────────────────────────────────────────────────────
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'aprobar_dispositivo';

  v_new := replace(v_def,
    $old$  v_es_mos boolean; v_accion text; v_lock jsonb; v_estado text; v_appdev text; v_val jsonb; v_upd int;$old$,
    $old$  v_es_mos boolean; v_accion text; v_lock jsonb; v_estado text; v_appdev text; v_val jsonb; v_upd int;
  -- [849] de dónde salió la aprobación: 'INSITU' (alguien con la clave, parado frente al equipo)
  -- o 'PANEL' (el buzón de MOS). Cambia lo que dice el aviso, no lo que hace la función.
  v_origen text := upper(btrim(coalesce(p->>'origen','')));
  v_quien  text; v_verbo text; v_equipo text;$old$);
  if v_new = v_def then raise exception '849: no se encontró el declare de aprobar_dispositivo'; end if;
  v_def := v_new;

  v_new := replace(v_def,
$old$  begin
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
      'titulo', '✅ Dispositivo aprobado',
      'cuerpo', coalesce(nullif(v_appdev,''),v_app,'app') || ' · ' || coalesce(nullif(v_nombre,''),'equipo') || ' · ya puede operar',
      'data', jsonb_build_object('tipo','device_aprobado','deviceId',v_id)));
  exception when others then null; end;$old$,
$old$  -- [849] El aviso cuenta lo que PASÓ, no pide nada: quién lo hizo, qué hizo y dónde.
  begin
    v_quien  := coalesce(nullif(btrim(coalesce(v_val->>'nombre','')),''), 'Un admin');
    v_verbo  := case when v_react then 'reactivó' else 'aprobó' end;
    v_equipo := coalesce(nullif(v_appdev,''), nullif(v_app,''), 'app') || ' · ' || coalesce(nullif(v_nombre,''),'equipo');
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
      'titulo', case when v_origen = 'INSITU'
                     then '✅ ' || v_quien || ' ' || v_verbo || ' un equipo'
                     else '✅ Equipo ' || case when v_react then 'reactivado' else 'aprobado' end || ' desde el panel' end,
      'cuerpo', case when v_origen = 'INSITU'
                     then 'in situ · ' || v_equipo || ' — ya puede operar, no tienes que hacer nada'
                     else v_quien || ' ' || v_verbo || ' ' || v_equipo || ' · ya puede operar' end,
      'data', jsonb_build_object('tipo','device_aprobado','deviceId',v_id,
                                 'origen', coalesce(nullif(v_origen,''),'PANEL'),
                                 'porQuien', v_quien, 'reactivacion', v_react)));
  exception when others then null; end;$old$);
  if v_new = v_def then raise exception '849: no se encontró el push de aprobar_dispositivo'; end if;
  execute v_new;
end $mig$;

commit;
