-- 803_semana_pickup_corta_lunes.sql — [DUEÑO · URGENTE] "hoy domingo WH no ve NINGUNA lista".
--
-- REGLA DEL DUEÑO (textual): «el acumulado empieza el lunes y termina todo el domingo. Lo que se
-- vende se agrega al acumulado, pero la venta del domingo aparece el lunes para que se empiece a
-- despachar, porque siempre se despacha un día después. El lunes se purga la lista y solo aparece
-- lo que las zonas vendieron el domingo, limpio; las deudas restantes pasan a ser el acumulado de
-- la semana pasada.»
--
-- QUÉ PASÓ (16-ago-2026 00:10:00, medido): el cron `wh-pickup-acumular` marcó REZAGADO los dos
-- acumuladores vivos —ZONA-01 con 526 productos / 3.741 u y ZONA-02 con 213 / 759 u— y no creó
-- los de la semana nueva (no había pickups fuente que los sembraran). WH pide PENDIENTE,EN_PROCESO
-- → lista vacía. La deuda NO se perdió: quedó íntegra en esas dos filas.
--
-- CAUSA RAÍZ — una sola función usada con DOS significados distintos.
--   `wh._bucket_dom(d) = date_trunc('week', d+1)::date - 1`
-- El `+1` es la doctrina "se despacha al día siguiente": una venta del día d se despacha el d+1,
-- así que pertenece a la semana del d+1. Eso es CORRECTO para clasificar una VENTA.
-- Pero la misma función se usaba para preguntar «¿en qué semana estamos HOY?» — y ahí el +1 sobra:
-- el domingo `_bucket_dom(hoy)` ya devolvía la semana SIGUIENTE, así que el corte caía el domingo
-- en vez del lunes. La semana moría un día antes, con todo el acumulado adentro.
--
-- FIX — se separan las dos semánticas, SIN cambiar el anclaje ni las claves de los id_pickup
-- (`PCK-ACU-<zona>-<YYYY-MM-DD>` sigue igual → los rezagados históricos y sus 4 semanas de
-- historial se leen exactamente como hoy; cero renombres, cero migración de datos):
--
--   wh._bucket_venta(d)    = wh._bucket_dom(d)       → semana en que se DESPACHARÁ lo vendido el día d.
--   wh._bucket_despacho(d) = wh._bucket_dom(d - 1)   → semana a la que pertenece un DESPACHO hecho
--                                                      el día d. Con d = hoy, es la semana vigente.
--
-- Ambas devuelven la MISMA clave para una venta y su despacho del día siguiente, que es lo que
-- hace que el neteo siga cuadrando.
--
-- COMPROBACIÓN de la nueva frontera (domingo 16-ago):
--   hoy dom 16 → _bucket_despacho(16) = _bucket_dom(15) = dom 09  → semana VIGENTE ✔ (WH ve todo)
--   lun 17     → _bucket_despacho(17) = _bucket_dom(16) = dom 16  → semana NUEVA   ✔ (corte el lunes)
--   mar 18     → _bucket_despacho(18) = _bucket_dom(17) = dom 16  → misma semana   ✔
--   dom 23     → _bucket_despacho(23) = _bucket_dom(22) = dom 16  → misma semana   ✔ (termina el dom)
--   lun 24     → _bucket_despacho(24) = _bucket_dom(23) = dom 23  → semana NUEVA   ✔
-- Y la venta del domingo: _bucket_venta(16) = dom 16 → NO se absorbe hoy (16 > 09); el lunes
-- siembra sola el acumulador nuevo. Exactamente "el lunes aparece limpio solo lo del domingo".

-- ── Las dos semánticas, con nombre propio ──
create or replace function wh._bucket_venta(d date)
returns date language sql immutable set search_path to '' as $$
  -- Semana en la que se despachará una venta del día d (se despacha al día siguiente).
  select wh._bucket_dom(d)
$$;

create or replace function wh._bucket_despacho(d date)
returns date language sql immutable set search_path to '' as $$
  -- Semana a la que pertenece un despacho hecho el día d. Con d = hoy → la semana vigente.
  -- El -1 cancela el +1 de _bucket_dom: un despacho de hoy sirve a la venta de ayer.
  select wh._bucket_dom(d - 1)
$$;

grant execute on function wh._bucket_venta(date), wh._bucket_despacho(date)
  to anon, authenticated, service_role;

-- ── Parcheo textual de los 6 consumidores, cada uno con su semántica ──
-- Se reescribe desde `pg_get_functiondef` (conserva firma, volatilidad, security definer y
-- search_path) y se EXIGE que cada reemplazo ocurra: si el texto objetivo cambió, la migración
-- falla en vez de dejar el sistema a medias.
create or replace function wh._mig803_patch(p_fn text, p_old text, p_new text, p_veces int)
returns void language plpgsql as $$
declare v_def text; v_new text; v_oid oid; v_n int;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'wh' and p.proname = p_fn
   order by p.oid limit 1;
  if v_oid is null then raise exception '[803] wh.% no existe', p_fn; end if;
  v_def := pg_get_functiondef(v_oid);
  v_n := (length(v_def) - length(replace(v_def, p_old, ''))) / nullif(length(p_old), 0);
  if v_n <> p_veces then
    raise exception '[803] wh.%: se esperaban % ocurrencias de "%" y hay %', p_fn, p_veces, p_old, v_n;
  end if;
  v_new := replace(v_def, p_old, p_new);
  execute v_new;
end $$;

-- (1) consolidar_pickups_todas — "¿en qué semana estamos?" + selección de pickups fuente (venta).
select wh._mig803_patch('consolidar_pickups_todas',
  'v_bucket date := wh._bucket_dom(v_today);',
  'v_bucket date := wh._bucket_despacho(v_today);   -- [803] semana VIGENTE (el domingo aún es de la semana en curso)', 1);
select wh._mig803_patch('consolidar_pickups_todas',
  'and wh._bucket_dom((fecha_creado at time zone ''America/Lima'')::date) = v_bucket',
  'and wh._bucket_venta((fecha_creado at time zone ''America/Lima'')::date) = v_bucket', 1);

-- (2) consolidar_pickup_zona — qué pickups fuente absorbe: se clasifican por VENTA.
select wh._mig803_patch('consolidar_pickup_zona',
  'and wh._bucket_dom((fecha_creado at time zone ''America/Lima'')::date) <= p_bucket',
  'and wh._bucket_venta((fecha_creado at time zone ''America/Lima'')::date) <= p_bucket', 1);

-- (3) _tg_pickup_consolidar — al crearse un pickup se consolida la semana VIGENTE, no la del
--     pickup: si no, el cierre de caja del domingo dispararía la semana siguiente esa misma noche
--     y volvería a matar el acumulado (justo el bug de hoy, doce horas antes).
select wh._mig803_patch('_tg_pickup_consolidar',
  'v_bucket := wh._bucket_dom((NEW.fecha_creado at time zone ''America/Lima'')::date);',
  'v_bucket := wh._bucket_despacho((now() at time zone ''America/Lima'')::date);   -- [803] semana vigente', 1);

-- (4) rebasar_acumulada — hoy (despacho) · cierre de caja (venta) · guía (despacho).
select wh._mig803_patch('rebasar_acumulada',
  'v_bucket date:=wh._bucket_dom((now() at time zone ''America/Lima'')::date);',
  'v_bucket date:=wh._bucket_despacho((now() at time zone ''America/Lima'')::date);', 1);
select wh._mig803_patch('rebasar_acumulada',
  'and wh._bucket_dom((coalesce(cj.fecha_cierre,cj.fecha_apertura) at time zone ''America/Lima'')::date)=v_bucket',
  'and wh._bucket_venta((coalesce(cj.fecha_cierre,cj.fecha_apertura) at time zone ''America/Lima'')::date)=v_bucket', 1);
select wh._mig803_patch('rebasar_acumulada',
  'and wh._bucket_dom((g.fecha at time zone ''America/Lima'')::date)=v_bucket',
  'and wh._bucket_despacho((g.fecha at time zone ''America/Lima'')::date)=v_bucket', 1);

-- (5) tg_considerado_ingreso — compara contra la semana vigente.
select wh._mig803_patch('tg_considerado_ingreso',
  'v_bucket := wh._bucket_dom((now() at time zone ''America/Lima'')::date);',
  'v_bucket := wh._bucket_despacho((now() at time zone ''America/Lima'')::date);', 1);

-- (6) zona_pickup_detalle — hoy (despacho) · pickups (venta) · guías de despacho (despacho).
select wh._mig803_patch('zona_pickup_detalle',
  'v_bucket date := wh._bucket_dom((now() at time zone ''America/Lima'')::date);',
  'v_bucket date := wh._bucket_despacho((now() at time zone ''America/Lima'')::date);', 1);
select wh._mig803_patch('zona_pickup_detalle',
  'wh._bucket_dom((pk.fecha_creado at time zone ''America/Lima'')::date) = v_bucket',
  'wh._bucket_venta((pk.fecha_creado at time zone ''America/Lima'')::date) = v_bucket', 2);
select wh._mig803_patch('zona_pickup_detalle',
  'and wh._bucket_dom((g.fecha at time zone ''America/Lima'')::date) = v_bucket',
  'and wh._bucket_despacho((g.fecha at time zone ''America/Lima'')::date) = v_bucket', 1);

-- (7) zona_rezagado_detalle — su v_bucket sale de la clave del propio acumulador REZAGADO,
--     así que solo hay que darle la semántica correcta a cada comparación.
select wh._mig803_patch('zona_rezagado_detalle',
  'wh._bucket_dom((pk.fecha_creado at time zone ''America/Lima'')::date)=v_bucket',
  'wh._bucket_venta((pk.fecha_creado at time zone ''America/Lima'')::date)=v_bucket', 1);
select wh._mig803_patch('zona_rezagado_detalle',
  'wh._bucket_dom((pk.fecha_creado at time zone ''America/Lima'')::date) = v_bucket',
  'wh._bucket_venta((pk.fecha_creado at time zone ''America/Lima'')::date) = v_bucket', 1);
select wh._mig803_patch('zona_rezagado_detalle',
  'and wh._bucket_dom((g.fecha at time zone ''America/Lima'')::date)=v_bucket',
  'and wh._bucket_despacho((g.fecha at time zone ''America/Lima'')::date)=v_bucket', 1);

drop function wh._mig803_patch(text,text,text,int);

-- ── REPARACIÓN DEL DAÑO DE HOY ──
-- Los acumuladores de la semana vigente vuelven a PENDIENTE. No se renombra nada: con la
-- frontera corregida, `PCK-ACU-<zona>-2026-08-09` ES la semana en curso (dom 09 → sáb 15 de
-- ventas, que se despachan de lun 10 a dom 16). Solo se revive lo que la purga prematura mató.
-- NOTA: la separación en curso (lo ya apartado y no despachado) fue borrada a las 00:10 por
-- `_items_sin_separacion` y NO es recuperable — no hay historial de esa columna. La deuda
-- (`solicitado`) está intacta; hay que volver a apartar.
update wh.pickups
   set estado = 'PENDIENTE', atendido_por = ''
 where fuente = 'ACUMULADO_SEMANAL'
   and upper(coalesce(estado,'')) = 'REZAGADO'
   and right(id_pickup, 10) ~ '^\d{4}-\d{2}-\d{2}$'
   and to_date(right(id_pickup, 10), 'YYYY-MM-DD')
       = wh._bucket_despacho((now() at time zone 'America/Lima')::date);
