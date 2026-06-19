-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 194_me_descontar_venta_presentacion_a_canonico.sql
-- TANDA 2/2 (referida en 192) · App de DINERO en PROD (flujo de VENTAS = core money). Money-safe, aditivo.
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- PROBLEMA (verificado): me.zona_descontar_venta (wrapper mos.zona_descontar_venta) descuenta me.stock_zonas del
--   cod_barra del item de venta TAL CUAL. El POS guarda la venta de una PRESENTACIÓN con cantidad = nº de
--   presentaciones (ej. PRE038 "25UN" → cantidad 1, NO 25 unidades base). Resultado: se descontaba la presentación
--   (PRE038) en vez del CANÓNICO, y por la cantidad cruda (1) en vez de las unidades base reales (1×25=25). Esto
--   (a) dejaba saldos fantasma negativos en filas de presentación de me.stock_zonas, y (b) NO descontaba el stock
--   real del canónico → el "Stock zona" del panel (que tras 192 suma SÓLO canónico+equivalentes) no reflejaba la
--   venta de presentaciones.
--
-- FIX (en me.zona_descontar_venta — ÚNICA vía de descuento de venta; ver "OTRAS VÍAS" abajo):
--   Cuando el cod_barra vendido es tipo_producto='PRESENTACION' Y su grupo (mismo sku_base) tiene EXACTAMENTE UN
--   CANÓNICO con codigo_barra no vacío y factor_conversion>0:
--     · descuenta el CANÓNICO por  cantidad × factor_conversion  (unidades base),
--     · registra el kardex me.stock_movimientos BAJO EL CANÓNICO, con ref/origen que traza que vino de una
--       venta-de-presentación (refTipo 'VENTA', refId conserva la clave por caja+presentación → MISMO dedup que
--       hoy: reaplicar la misma caja NO vuelve a descontar; tipo 'SALIDA_VENTA' + origen anotado con la presentación).
--   En CUALQUIER otro caso (no es presentación; o es presentación pero su grupo NO mapea limpio a un único
--   canónico-con-código / factor inválido) → se descuenta el código TAL CUAL como hoy (sin ×factor). Money-safe:
--   ante mapeo ambiguo NO se adivina; el camino legacy queda intacto.
--
--   UPDATE ATÓMICO (cantidad − delta) sobre me.stock_zonas, nunca read-modify-write. Si la fila del canónico no
--   existe, se crea (igual que hoy con el código crudo). El KARDEX sigue siendo el guardián de idempotencia por
--   (caja, código vendido): si dedup=true → NO se vuelve a restar.
--
-- MIGRACIÓN (las 8 filas de presentación con stock<0 que 192 dejó intactas por tener kardex):
--   Por cada fila me.stock_zonas (tipo PRESENTACION) con cantidad<0, mueve su negativo al CANÓNICO en unidades
--   base = stock_pres × factor (UPDATE ATÓMICO: canónico.cantidad += stock_pres×factor, que es negativo → baja) y
--   pone la presentación en 0. Sólo si el mapeo es LIMPIO (1 canónico con código + factor>0); las que no, se
--   listan y NO se tocan. Idempotente vía me.riz_migracion_presentaciones_log (no re-aplica si ya migrada).
--   Reversible: el log guarda cod_pres, zona, stock_pres, factor y delta_canonico_aplicado.
--
-- OTRAS VÍAS DE DESCUENTO DE VENTA — verificado: NINGUNA otra escribe me.stock_zonas en una venta.
--   · me.crear_venta_directa (23) sólo inserta me.ventas / me.ventas_detalle (NO toca stock).
--   · me.cierre_datos_caja (160) es SOLO LECTURA; arma totales_por_cod que GAS pasa a me.zona_descontar_venta.
--   · Los demás writers de me.stock_zonas son ajustes (129/135/185), traslados (141/144) y recepción de guía
--     WH→zona (146/147/151/175): mueven UNIDADES FÍSICAS por canónico/equivalente, NO presentaciones — y por la
--     regla del dueño (133) "las presentaciones SÓLO aplican a ventas, no al despacho de almacén a zona". No se tocan.
--
-- IDEMPOTENTE (create or replace + log de migración con guard). No toca: shape de salida de la RPC, gates,
--   grants, search_path, wrapper mos.zona_descontar_venta, flags, sync, frontend, version.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

set search_path to '';

-- ╔══════════════════════════════════════════════════════════════════════════════════════════════════════════╗
-- ║ HELPER · me._venta_resolver_descuento(cod_vendido) → a qué código y con qué factor se descuenta.            ║
-- ║   Devuelve (cod_destino, factor, es_presentacion, mapeo_limpio).                                            ║
-- ║   · es_presentacion=true  + mapeo_limpio=true  → cod_destino = canónico, factor = factor_conversion (>0).   ║
-- ║   · cualquier otro caso → cod_destino = cod_vendido, factor = 1 (camino legacy, sin ×factor).               ║
-- ║   STABLE: lee sólo catálogo. No adivina ante ambigüedad (0 ó >1 canónicos / factor inválido → legacy).      ║
-- ╚══════════════════════════════════════════════════════════════════════════════════════════════════════════╝
create or replace function me._venta_resolver_descuento(p_cod text)
returns table (cod_destino text, factor numeric, es_presentacion boolean, mapeo_limpio boolean)
language plpgsql
stable
security definer
set search_path to ''
as $fn$
declare
  v_cod      text := upper(btrim(coalesce(p_cod,'')));
  v_sku      text;
  v_factor   numeric;
  v_canon    text;
  v_n_canon  int;
begin
  cod_destino := v_cod; factor := 1; es_presentacion := false; mapeo_limpio := false;
  if v_cod = '' then return next; return; end if;

  -- ¿El código vendido es una PRESENTACIÓN del catálogo? (tomar su sku_base y factor)
  select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto),
         case when coalesce(pr.factor_conversion,0) > 0 then pr.factor_conversion else null end
    into v_sku, v_factor
    from mos.productos pr
   where upper(btrim(pr.codigo_barra)) = v_cod
     and pr.tipo_producto = 'PRESENTACION'
   limit 1;

  if v_sku is null then
    -- No es presentación (o no está en catálogo) → legacy: descontar tal cual, factor 1.
    return next; return;
  end if;
  es_presentacion := true;

  -- factor inválido (null/0) → NO normalizar (legacy, factor 1). Money-safe.
  if v_factor is null then return next; return; end if;

  -- Grupo del sku_base: debe haber EXACTAMENTE UN canónico con codigo_barra no vacío.
  select count(*) filter (where c.tipo_producto='CANONICO' and nullif(btrim(c.codigo_barra),'') is not null),
         max(upper(btrim(c.codigo_barra))) filter (where c.tipo_producto='CANONICO' and nullif(btrim(c.codigo_barra),'') is not null)
    into v_n_canon, v_canon
    from mos.productos c
   where coalesce(nullif(btrim(c.sku_base),''), c.id_producto) = v_sku;

  if coalesce(v_n_canon,0) <> 1 or v_canon is null then
    -- Mapeo ambiguo (0 ó >1 canónicos con código) → NO adivinar; legacy (descontar la presentación tal cual).
    return next; return;
  end if;

  -- Mapeo LIMPIO: normalizar a canónico × factor.
  cod_destino := v_canon; factor := v_factor; mapeo_limpio := true;
  return next;
end;
$fn$;
revoke all on function me._venta_resolver_descuento(text) from public;
grant execute on function me._venta_resolver_descuento(text) to service_role, authenticated;


-- ╔══════════════════════════════════════════════════════════════════════════════════════════════════════════╗
-- ║ me.zona_descontar_venta — normaliza PRESENTACIÓN → CANÓNICO × factor. Resto IDÉNTICO a 148.                 ║
-- ╚══════════════════════════════════════════════════════════════════════════════════════════════════════════╝
create or replace function me.zona_descontar_venta(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_caja   text := btrim(coalesce(p->>'idCaja',''));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'GAS');
  v_items  jsonb := coalesce(p->'items', '[]'::jsonb);
  v_e      jsonb;
  v_cb     text;            -- código VENDIDO (tal cual viene del POS)
  v_cant   numeric(20,3);   -- cantidad VENDIDA (nº de presentaciones / unidades, según el item)
  -- normalización presentación→canónico:
  v_dst    text;            -- código a descontar (canónico si presentación limpia; si no, el vendido)
  v_factor numeric;         -- factor a aplicar (factor_conversion si presentación limpia; si no, 1)
  v_espres boolean;
  v_limpio boolean;
  v_delta  numeric(20,3);   -- unidades base a restar = v_cant × v_factor
  v_korig  text;            -- origen del kardex (anota la presentación de procedencia para trazabilidad)
  v_kres   jsonb;
  v_aplicados int := 0;
  v_dedup     int := 0;
  v_resultado jsonb := '[]'::jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_caja = '' then return jsonb_build_object('ok',false,'error','Requiere idCaja'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  -- Agregar por código VENDIDO (defensa: sumar si el array trae el mismo código en varias líneas).
  create temp table if not exists _venta_agg (cod_barra text primary key, cant numeric) on commit drop;
  truncate _venta_agg;
  for v_e in select * from jsonb_array_elements(v_items) loop
    v_cb   := upper(btrim(coalesce(v_e->>'codBarra', v_e->>'cod_barras', v_e->>'cod_barra', '')));
    v_cant := coalesce((v_e->>'cantidad')::numeric, 0);
    if v_cb = '' or v_cant <= 0 then continue; end if;
    insert into _venta_agg(cod_barra, cant) values (v_cb, v_cant)
      on conflict (cod_barra) do update set cant = _venta_agg.cant + excluded.cant;
  end loop;

  for v_cb, v_cant in select cod_barra, cant from _venta_agg loop
    -- [194] Resolver destino real del descuento: presentación limpia → canónico × factor; si no, código tal cual.
    select r.cod_destino, r.factor, r.es_presentacion, r.mapeo_limpio
      into v_dst, v_factor, v_espres, v_limpio
      from me._venta_resolver_descuento(v_cb) r;
    v_factor := coalesce(v_factor, 1);
    v_dst    := coalesce(nullif(v_dst,''), v_cb);
    v_delta  := v_cant * v_factor;       -- unidades base a restar (= v_cant cuando factor=1 → idéntico a 148)

    -- origen del kardex: traza la presentación de procedencia cuando hubo normalización.
    v_korig := case when v_espres and v_limpio
                    then v_origen || ' | venta-presentacion ' || v_cb || ' x' || trim(to_char(v_factor,'FM999990.######'))
                    else v_origen end;

    -- KARDEX primero (guardián de idempotencia por id_caja + CÓDIGO VENDIDO → reaplicar la misma caja no re-resta).
    --   refId conserva el código VENDIDO (v_cb), NO el destino: misma clave de dedup que 148, sin cambiar la huella.
    --   codBarra del kardex = v_dst (canónico cuando aplica) → la trazabilidad queda bajo el canónico, con saldo
    --   corrido del canónico. tipo SALIDA_VENTA, delta = −v_delta (unidades base).
    v_kres := me.zona_kardex_registrar(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_dst, 'tipo', 'SALIDA_VENTA', 'delta', (-v_delta),
      'refTipo', 'VENTA', 'refId', 'VENTA-CAJA:'||v_caja||':'||v_cb, 'usuario', v_user, 'origen', v_korig));

    if coalesce((v_kres->>'dedup')::boolean, false) then
      v_dedup := v_dedup + 1;   -- esta caja+código YA se descontó → NO restar otra vez.
    else
      -- UPDATE ATÓMICO (resta) sobre el DESTINO (canónico o código tal cual). Insert si no existe la fila.
      insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
        values (v_dst, v_zona, -v_delta, v_user, now())
      on conflict (cod_barras, zona_id) do update
        set cantidad = coalesce(me.stock_zonas.cantidad,0) - v_delta,
            usuario = excluded.usuario, fecha_ultimo_registro = now();
      v_aplicados := v_aplicados + 1;
    end if;
    v_resultado := v_resultado || jsonb_build_object(
      'codBarra', v_cb, 'cantidad', v_cant,
      'codDescontado', v_dst, 'factor', v_factor, 'unidadesBase', v_delta,
      'normalizadoPresentacion', (v_espres and v_limpio),
      'aplicado', not coalesce((v_kres->>'dedup')::boolean,false));
  end loop;

  return jsonb_build_object('ok', true, 'idCaja', v_caja, 'zona', v_zona,
    'aplicados', v_aplicados, 'dedup', v_dedup, 'detalle', v_resultado);
end;
$function$;

revoke all on function me.zona_descontar_venta(jsonb) from public;
grant execute on function me.zona_descontar_venta(jsonb) to service_role, authenticated;


-- ╔══════════════════════════════════════════════════════════════════════════════════════════════════════════╗
-- ║ MIGRACIÓN · mover el negativo de presentaciones a su canónico (unidades base), idempotente y reversible.    ║
-- ╚══════════════════════════════════════════════════════════════════════════════════════════════════════════╝
create table if not exists me.riz_migracion_presentaciones_log (
  id                       bigserial primary key,
  cod_pres                 text not null,
  zona_id                  text not null,
  stock_pres               numeric not null,   -- saldo (negativo) que tenía la presentación antes de migrar
  factor                   numeric not null,
  cod_canonico             text not null,
  delta_canonico_aplicado  numeric not null,   -- = stock_pres × factor (negativo) sumado al canónico
  canonico_antes           numeric,            -- saldo del canónico ANTES (trazabilidad)
  canonico_despues         numeric,            -- saldo del canónico DESPUÉS (trazabilidad)
  motivo                   text not null default 'venta-presentacion-no-normalizada-historica',
  ts                       timestamptz not null default now(),
  unique (cod_pres, zona_id)                    -- idempotencia: una presentación×zona se migra UNA sola vez
);

do $mig$
declare
  r           record;
  v_canon     text;
  v_n_canon   int;
  v_factor    numeric;
  v_delta     numeric;
  v_antes     numeric;
  v_despues   numeric;
  v_migradas  int := 0;
  v_saltadas  int := 0;
begin
  for r in
    select z.cod_barras, z.zona_id, z.cantidad, p.factor_conversion,
           coalesce(nullif(btrim(p.sku_base),''), p.id_producto) as sku
      from me.stock_zonas z
      join mos.productos p on upper(btrim(p.codigo_barra)) = upper(btrim(z.cod_barras))
     where p.tipo_producto = 'PRESENTACION'
       and coalesce(z.cantidad,0) < 0
       -- idempotencia: no re-migrar lo ya registrado.
       and not exists (
         select 1 from me.riz_migracion_presentaciones_log l
          where l.cod_pres = z.cod_barras and l.zona_id = z.zona_id)
  loop
    v_factor := r.factor_conversion;

    -- mapeo LIMPIO: exactamente 1 canónico con código en el grupo, y factor>0.
    select count(*) filter (where c.tipo_producto='CANONICO' and nullif(btrim(c.codigo_barra),'') is not null),
           max(upper(btrim(c.codigo_barra))) filter (where c.tipo_producto='CANONICO' and nullif(btrim(c.codigo_barra),'') is not null)
      into v_n_canon, v_canon
      from mos.productos c
     where coalesce(nullif(btrim(c.sku_base),''), c.id_producto) = r.sku;

    if coalesce(v_factor,0) <= 0 or coalesce(v_n_canon,0) <> 1 or v_canon is null then
      v_saltadas := v_saltadas + 1;
      raise notice '[194][MIG][SALTADA] % zona % : mapeo no limpio (n_canon=%, factor=%) → NO migrada',
        r.cod_barras, r.zona_id, v_n_canon, v_factor;
      continue;
    end if;

    v_delta := r.cantidad * v_factor;   -- negativo (la presentación está en negativo)

    -- saldo del canónico ANTES (en esa misma zona) — sólo para trazabilidad del log.
    select coalesce(cantidad,0) into v_antes
      from me.stock_zonas where cod_barras = v_canon and zona_id = r.zona_id;
    v_antes := coalesce(v_antes, 0);

    -- UPDATE ATÓMICO del canónico (suma el delta negativo). Crea la fila si no existe.
    insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
      values (v_canon, r.zona_id, v_delta, 'sistema-migracion-194', now())
    on conflict (cod_barras, zona_id) do update
      set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_delta,
          usuario = 'sistema-migracion-194', fecha_ultimo_registro = now()
    returning cantidad into v_despues;

    -- presentación a 0 (UPDATE atómico directo — la fila existe por definición del loop).
    update me.stock_zonas
       set cantidad = 0, usuario = 'sistema-migracion-194', fecha_ultimo_registro = now()
     where cod_barras = r.cod_barras and zona_id = r.zona_id;

    insert into me.riz_migracion_presentaciones_log
      (cod_pres, zona_id, stock_pres, factor, cod_canonico, delta_canonico_aplicado, canonico_antes, canonico_despues)
    values
      (r.cod_barras, r.zona_id, r.cantidad, v_factor, v_canon, v_delta, v_antes, v_despues);

    v_migradas := v_migradas + 1;
    raise notice '[194][MIG][OK] % zona % : % x % = % → canónico % (% → %)',
      r.cod_barras, r.zona_id, r.cantidad, v_factor, v_delta, v_canon, v_antes, v_despues;
  end loop;

  raise notice '[194][MIG] migradas=% saltadas=%', v_migradas, v_saltadas;
end;
$mig$;
