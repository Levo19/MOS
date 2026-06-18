-- 143_wh_autocierre_idempotente.sql
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- CIERRE DE GUÍAS IDEMPOTENTE (100% Supabase) — red de seguridad contra la re-aplicación de stock.
--
-- EL BUG (confirmado en datos reales):
--   `wh.cerrar_guia` (35) y `wh.autocerrar_guias_viejas` (70) aplican el delta COMPLETO desde la base vieja en
--   CADA cierre. Una guía ya aplicada (por GAS o por un cierre previo) que se vuelve a cerrar (o que el cron
--   nocturno toca de nuevo) re-resta/re-suma todo el detalle → DUPLICA stock. Evidencia: la guía SALIDA_ZONA
--   G1781445112212 ya tenía 59 movimientos legítimos (MOV_*), y el cron viejo de 70 disparó las noches del
--   16 y 17-jun inyectando 59 movimientos DUPLICADOS (MOVAC_*, Σ delta = -954) → LOPESA SALSA (7751037001760)
--   bajó 288 → 216 (correcto) → 144 (BUG, doble resta). Los 79 dups previos ya se limpiaron a mano; estos 59
--   MOVAC_ se limpian en el PASO 0 de este script.
--
-- LA SOLUCIÓN: reconciliación por delta usando wh.guia_detalle.cantidad_aplicada (columna aditiva de 142).
--   Cada línea recuerda cuánto YA impactó el stock. Cerrar aplica SOLO (cant_recibida − cantidad_aplicada) y
--   luego setea cantidad_aplicada = cant_recibida. Recerrar sin cambios → delta 0 → NO toca stock ni kardex.
--   El movimiento de kardex usa un origen ÚNICO determinista (id_guia#linea) → on conflict do nothing protege
--   también la TRAZA. Reabrir NO revierte stock (coherente con el modelo: lo revierte editar/anular detalle).
--
-- PATRÓN RPC ESTÁNDAR: security definer · set search_path='' · revoke public · grant service_role.
-- 100% Supabase / pg_cron — NADA de GAS, NADA de clasp.
-- Idempotente de punta a punta: re-correr este script completo es no-op seguro.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists wh;
create schema if not exists mos;
create extension if not exists pg_cron;


-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PASO 0 — REVERTIR LOS 59 MOVIMIENTOS DUPLICADOS (MOVAC_*) DEL CRON VIEJO (70) Y BORRARLOS.
--   Antes de reconciliar cantidad_aplicada hay que dejar wh.stock en su valor REAL (una sola aplicación).
--   Los MOVAC_ son duplicados perfectos de los MOV_* legítimos (verificado: 0 discrepancia por producto).
--   Para revertir: a cada producto le SUMAMOS de vuelta el negativo del delta duplicado (devuelve el stock),
--   con UPDATE ATÓMICO (cantidad + delta inverso, nunca read-modify-write), y luego borramos los MOVAC_.
--   Envuelto para ser idempotente: si ya no hay MOVAC_ (re-corrida), el bloque no hace nada.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
do $reverse$
declare
  v_m record;
  v_rev numeric := 0;
  v_n   int := 0;
begin
  -- Sumar de vuelta (revertir) cada MOVAC_ a su producto. Agrupamos por producto: el inverso del delta total.
  for v_m in
    select cod_producto, sum(delta) as d
      from wh.stock_movimientos
     where id_mov like 'MOVAC\_%'
     group by cod_producto
  loop
    -- UPDATE atómico de la 1ra fila de stock del producto (misma regla que cerrar_guia). delta inverso.
    update wh.stock
       set cantidad_disponible = cantidad_disponible + (-v_m.d), ultima_actualizacion = now()
     where id_stock = (select id_stock from wh.stock where cod_producto = v_m.cod_producto order by id_stock limit 1);
    v_rev := v_rev + 1;
  end loop;

  -- Borrar los movimientos duplicados (ya revertido su efecto en stock). Idempotente: 0 filas si no hay.
  delete from wh.stock_movimientos where id_mov like 'MOVAC\_%';
  get diagnostics v_n = row_count;

  raise notice '[PASO 0] productos revertidos=% · movimientos MOVAC_ borrados=%', v_rev, v_n;
end
$reverse$;


-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PASO 1 — RECONCILIAR cantidad_aplicada (CRÍTICO: protege contra re-aplicar).
--   Regla: toda LÍNEA cuya GUÍA ya impactó el kardex (tiene movimientos en wh.stock_movimientos con
--   origen = id_guia) arranca con cantidad_aplicada = cant_recibida → su cierre dará delta 0. El resto en 0.
--   Tras el PASO 0, los únicos movimientos que quedan por origen=guia son los LEGÍTIMOS (una aplicación).
--   Esto cubre: las ~571 guías CERRADA + la guía abierta-pero-aplicada G1781445112212 (59 líneas).
--   La guía de devolución G_L17817175748130rg8d30 (0 movs) queda en 0 → su cierre aplicará una sola vez.
--   Idempotente: re-correr deja el mismo valor (cant_recibida o 0).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
update wh.guia_detalle d
   set cantidad_aplicada = case
         when exists (select 1 from wh.stock_movimientos m where m.origen = d.id_guia)
         then coalesce(d.cant_recibida, 0)
         else 0
       end;


-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PASO 2 — TRIGGER de ULTIMA_ACTIVIDAD (100% Supabase).
--   Actualiza wh.guias.ultima_actividad = now() SOLO cuando cant_recibida REALMENTE cambia (WHEN guard).
--   El sync GAS reupserta TODO el detalle en cada pasada; sin el WHEN, ultima_actividad nunca envejecería y
--   el auto-cierre por inactividad jamás dispararía. También en INSERT de una línea nueva (actividad real).
--   Inicializa ultima_actividad = coalesce(ultima_actividad, fecha) para las existentes (reloj base).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function wh._tg_guia_detalle_actividad()
returns trigger
language plpgsql
security definer
set search_path = ''
as $tg$
begin
  -- toca la cabecera (no falla si la guía aún no existe en la sombra)
  update wh.guias set ultima_actividad = now() where id_guia = new.id_guia;
  return new;
end;
$tg$;

drop trigger if exists tg_wh_guia_detalle_actividad_ins on wh.guia_detalle;
drop trigger if exists tg_wh_guia_detalle_actividad_upd on wh.guia_detalle;

-- INSERT: cualquier línea nueva = actividad real.
create trigger tg_wh_guia_detalle_actividad_ins
  after insert on wh.guia_detalle
  for each row execute function wh._tg_guia_detalle_actividad();

-- UPDATE: SOLO si cant_recibida cambió (ignora re-syncs no-op del dual-write GAS).
create trigger tg_wh_guia_detalle_actividad_upd
  after update on wh.guia_detalle
  for each row
  when (old.cant_recibida is distinct from new.cant_recibida)
  execute function wh._tg_guia_detalle_actividad();

-- Inicializar el reloj de las guías existentes (no pisa si ya tiene valor).
update wh.guias set ultima_actividad = coalesce(ultima_actividad, fecha) where ultima_actividad is null;


-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PASO 3 — RPC wh.cerrar_guia_idempotente(p_id_guia text)
--   Por cada línea: delta = cant_recibida − cantidad_aplicada.
--     · delta = 0 → SKIP (no toca stock ni kardex) → recerrar es no-op.
--     · delta ≠ 0 → UPDATE ATÓMICO de stock (cantidad + (esIngreso?+delta:−delta)) + INSERT en kardex con
--                   origen único (id_guia#linea, on conflict do nothing) + SET cantidad_aplicada = cant_recibida.
--   esIngreso: tipo like 'INGRESO%' o 'ENTRADA%' suma; 'SALIDA%' resta.
--   ENVASADO (INGRESO_ENVASADO/SALIDA_ENVASADO): NO toca stock (lo aplica Envasados); solo marca CERRADA.
--   FOR UPDATE en la cabecera: serializa cierres concurrentes. Atómica (1 tx). Estado final = CERRADA.
--   GATE: solo service_role (el cron y el caller server-side). NO usa _claim_ok ni el kill-switch interactivo.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function wh.cerrar_guia_idempotente(p_id_guia text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id        text := nullif(btrim(coalesce(p_id_guia,'')), '');
  v_estado    text;
  v_tipo      text;
  v_ingreso   boolean;
  v_envasado  boolean;
  v_monto     numeric := 0;
  v_d         record;
  v_cod       text;
  v_cant      numeric;
  v_apl       numeric;
  v_delta     numeric;   -- cant_recibida − cantidad_aplicada (lo que falta aplicar)
  v_signo     numeric;   -- delta de stock con signo según ingreso/salida
  v_antes     numeric;
  v_despues   numeric;
  v_idmov     text;
  v_aplicadas int := 0;
  v_saltadas  int := 0;
begin
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- lock de cabecera: serializa contra cierres concurrentes (doble-tap / cron + manual)
  select estado, tipo into v_estado, v_tipo from wh.guias where id_guia = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  v_tipo     := upper(coalesce(v_tipo,''));
  v_ingreso  := (v_tipo like 'INGRESO%' or v_tipo like 'ENTRADA%');
  v_envasado := v_tipo in ('INGRESO_ENVASADO','SALIDA_ENVASADO');

  -- monto total = Σ(cant_recibida × precio_unitario)   (igual que cerrar_guia)
  select coalesce(sum(wh._num(cant_recibida::text) * wh._num(precio_unitario::text)), 0)
    into v_monto from wh.guia_detalle where id_guia = v_id;

  -- aplicar por detalle (saltar si envasado: el stock ya lo aplicó Envasados)
  if not v_envasado then
    for v_d in
      select linea, cod_producto, cant_recibida, cantidad_aplicada
        from wh.guia_detalle
       where id_guia = v_id
       order by linea asc nulls last
    loop
      v_cod  := nullif(btrim(v_d.cod_producto), '');
      v_cant := wh._num(v_d.cant_recibida::text);
      v_apl  := wh._num(coalesce(v_d.cantidad_aplicada, 0)::text);
      v_delta := v_cant - v_apl;

      -- línea sin producto → solo alinear marca, sin stock
      if v_cod is null then
        update wh.guia_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
        continue;
      end if;

      -- delta 0 → SKIP TOTAL: no toca stock ni kardex. (red de seguridad anti-duplicado)
      if v_delta = 0 then
        v_saltadas := v_saltadas + 1;
        continue;
      end if;

      v_signo := case when v_ingreso then v_delta else -v_delta end;
      -- origen único por línea: una sola fila de kardex por (guia, linea) aunque se recierre N veces.
      v_idmov := 'MOVID_' || v_id || '#' || v_d.linea;

      -- ── stock ATÓMICO: cantidad + signo (nunca read-modify-write). 1ra fila por producto (como GAS).
      update wh.stock
         set cantidad_disponible = cantidad_disponible + v_signo, ultima_actualizacion = now()
       where id_stock = (select id_stock from wh.stock where cod_producto = v_cod order by id_stock limit 1)
       returning cantidad_disponible into v_despues;
      if found then
        v_antes := v_despues - v_signo;
      else
        v_antes := 0; v_despues := v_signo;
        insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
        values ('STK'||v_id||'_'||v_cod, v_cod, v_despues, now());
      end if;

      -- kardex con origen único (id_guia#linea) → on conflict do nothing protege la traza
      insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
      values (v_idmov, now(), v_cod, v_signo, v_antes, v_despues, 'CIERRE_GUIA', v_id, 'sistema-cierre-idem')
      on conflict (id_mov) do nothing;

      -- marcar la línea como aplicada al 100% (recerrar dará delta 0)
      update wh.guia_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
      v_aplicadas := v_aplicadas + 1;
    end loop;
  end if;

  -- cerrar cabecera
  update wh.guias set estado = 'CERRADA', monto_total = v_monto where id_guia = v_id;

  return jsonb_build_object('ok', true, 'id_guia', v_id, 'estado', 'CERRADA',
    'montoTotal', v_monto, 'lineasAplicadas', v_aplicadas, 'lineasSaltadas', v_saltadas,
    'eraEstado', v_estado);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM, 'id_guia', v_id);
end;
$fn$;

revoke all on function wh.cerrar_guia_idempotente(text) from public, anon, authenticated;
grant execute on function wh.cerrar_guia_idempotente(text) to service_role;


-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PASO 4a — config WH_AUTOCIERRE_MIN (default 30) en mos.config.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
insert into mos.config (clave, valor, descripcion) values
  ('WH_AUTOCIERRE_MIN','30','WH: minutos de inactividad (sin cambios de cant_recibida) para autocerrar una guia ABIERTA.')
on conflict (clave) do nothing;


-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PASO 4b — RPC wh.autocerrar_guias_inactivas()
--   Cierra (con wh.cerrar_guia_idempotente) las guías ABIERTA cuya inactividad supera WH_AUTOCIERRE_MIN min:
--     now() − coalesce(ultima_actividad, fecha) > intervalo.
--   Excluye ENVASADO (INGRESO_ENVASADO/SALIDA_ENVASADO). Cada guía en su propio begin/exception (un error en
--   una NO rompe el cron ni las demás). Loguea el resumen en mos.cron_log (job='wh_autocierre_inactividad').
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function wh.autocerrar_guias_inactivas()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_min      int := coalesce((select wh._num(valor)::int from mos.config where clave='WH_AUTOCIERRE_MIN' limit 1), 30);
  v_g        record;
  v_res      jsonb;
  v_cerradas int := 0;
  v_errores  int := 0;
  v_detalle  jsonb := '[]'::jsonb;
begin
  for v_g in
    select id_guia
      from wh.guias
     where upper(coalesce(estado,'')) = 'ABIERTA'
       and upper(coalesce(tipo,'')) not in ('INGRESO_ENVASADO','SALIDA_ENVASADO')
       and now() - coalesce(ultima_actividad, fecha) > make_interval(mins => v_min)
     order by coalesce(ultima_actividad, fecha) asc
  loop
    begin
      v_res := wh.cerrar_guia_idempotente(v_g.id_guia);
      if coalesce((v_res->>'ok')::boolean, false) then
        v_cerradas := v_cerradas + 1;
      else
        v_errores := v_errores + 1;
      end if;
      v_detalle := v_detalle || jsonb_build_object('id_guia', v_g.id_guia, 'rpc', v_res);
    exception when others then
      v_errores := v_errores + 1;
      v_detalle := v_detalle || jsonb_build_object('id_guia', v_g.id_guia, 'error', SQLERRM);
    end;
  end loop;

  -- bitácora (mos.cron_log ya existe desde 97). No es dato de negocio.
  begin
    insert into mos.cron_log(job, ok, resultado)
      values ('wh_autocierre_inactividad', v_errores = 0,
              jsonb_build_object('minInactividad', v_min, 'cerradas', v_cerradas, 'errores', v_errores, 'detalle', v_detalle));
  exception when others then null;  -- el log nunca debe romper el cron
  end;

  return jsonb_build_object('ok', true, 'minInactividad', v_min, 'cerradas', v_cerradas, 'errores', v_errores, 'detalle', v_detalle);
end;
$fn$;

revoke all on function wh.autocerrar_guias_inactivas() from public, anon, authenticated;
grant execute on function wh.autocerrar_guias_inactivas() to service_role;


-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PASO 4c — pg_cron: 'wh-autocierre-inactividad' cada 15 min.
--   ⚠️ DESAGENDA EL CRON NOCTURNO BUGGY 'wh-autocierre' (70_wh_autocerrar_guias_viejas) — ESE es el que
--   inyectó los 59 MOVAC_ duplicados (re-aplica delta completo desde base vieja). Lo reemplaza este, que
--   delega en wh.cerrar_guia_idempotente (delta-reconciliado). La auditoría de cuadre 'wh-auditar-cuadre' se
--   mantiene intacta. Idempotente: desagenda si ya existía antes de re-agendar.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
select cron.unschedule('wh-autocierre')              where exists (select 1 from cron.job where jobname='wh-autocierre');
select cron.unschedule('wh-autocierre-inactividad')  where exists (select 1 from cron.job where jobname='wh-autocierre-inactividad');

select cron.schedule('wh-autocierre-inactividad', '*/15 * * * *', $$ select wh.autocerrar_guias_inactivas(); $$);
