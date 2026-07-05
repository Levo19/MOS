-- ════════════════════════════════════════════════════════════════════════════
-- 367 · FIXES de la revisión 100x sobre 366 (seguridad/dinero). Redefine 5 RPCs.
--   CRÍTICO-1: rotar_clave_admin ignoraba pinAdmin → cualquier device MOS rotaba
--     la clave global. Ahora exige pinAdmin de un admin real (como el GAS).
--   CRÍTICO-2: set_config podía desincronizar ADMIN_GLOBAL_PIN vs _HASH → rechaza
--     las claves sensibles (solo rotar_clave_admin las toca, atómico).
--   ALTO-1: crear/actualizar_personal seteaban `pin` texto pero NO `pin_hash` →
--     el admin creado no podía autenticar. Ahora setea pin_hash = bcrypt(pin).
--   MEDIO-1: actualizar_costo_sku podía tocar >1 fila por skuBase → error ambiguo.
--   MEDIO-2: crear_categoria `do update` pisaba una existente → `do nothing`.
-- ════════════════════════════════════════════════════════════════════════════

-- ── set_config: rechazar claves sensibles del PIN global ──────────────────────
create or replace function mos.set_config(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_clave text := nullif(btrim(coalesce(p->>'clave','')),''); v_val text := coalesce(p->>'valor','');
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_clave is null then return jsonb_build_object('ok',false,'error','clave requerida'); end if;
  -- [fix CRÍTICO-2] El PIN global solo se rota por mos.rotar_clave_admin (escribe texto+hash atómico). Un
  -- set_config sobre estas claves desincronizaría el hash que valida verificar_clave_admin.
  if upper(v_clave) in ('ADMIN_GLOBAL_PIN','ADMIN_GLOBAL_PIN_HASH','ADMIN_GLOBAL_PIN_FECHA') then
    return jsonb_build_object('ok',false,'error','Clave protegida: usa rotar_clave_admin');
  end if;
  insert into mos.config(clave,valor) values (v_clave, v_val)
  on conflict (clave) do update set valor = excluded.valor;
  return jsonb_build_object('ok',true);
end; $fn$;

-- ── actualizar_costo_sku: error si el fallback por skuBase toca >1 fila ────────
create or replace function mos.actualizar_costo_sku(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_sku  text := nullif(btrim(coalesce(p->>'sku','')),'');
  v_cost numeric := nullif(btrim(coalesce(p->>'precioCosto','')),'')::numeric;
  v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sku is null or v_cost is null then return jsonb_build_object('ok',false,'error','Requiere sku y precioCosto'); end if;
  update mos.productos set precio_costo = v_cost, updated_at = now() where id_producto = v_sku;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    update mos.productos set precio_costo = v_cost, updated_at = now() where upper(btrim(codigo_barra)) = upper(v_sku);
    get diagnostics v_n = row_count;
  end if;
  if v_n = 0 then
    -- [fix MEDIO-1] canónico por skuBase; si es AMBIGUO (>1 fila) NO commitear a ciegas.
    select count(*) into v_n from mos.productos
     where coalesce(nullif(btrim(sku_base),''), id_producto) = v_sku and coalesce(factor_conversion,1) = 1;
    if v_n > 1 then return jsonb_build_object('ok',false,'error','skuBase ambiguo ('||v_n||' filas) — usa idProducto'); end if;
    update mos.productos set precio_costo = v_cost, updated_at = now()
     where coalesce(nullif(btrim(sku_base),''), id_producto) = v_sku and coalesce(factor_conversion,1) = 1;
    get diagnostics v_n = row_count;
  end if;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','SKU no encontrado: '||v_sku); end if;
  return jsonb_build_object('ok',true,'filas',v_n);
end; $fn$;

-- ── crear_personal: setear pin_hash (bcrypt) junto al pin ─────────────────────
create or replace function mos.crear_personal(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_nom text := nullif(btrim(coalesce(p->>'nombre','')),'');
  v_id  text := nullif(btrim(coalesce(p->>'idPersonal','')),'');
  v_pin text := nullif(btrim(coalesce(p->>'pin','')),'');
  v_est boolean := coalesce(nullif(btrim(coalesce(p->>'estado','')),'')::boolean, true);
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null then return jsonb_build_object('ok',false,'error','nombre requerido'); end if;
  if v_id is null then v_id := 'PER' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS') || substr(md5(random()::text),1,3); end if;
  insert into mos.personal (id_personal, nombre, apellido, tipo, app_origen, rol, pin, pin_hash, color,
    tarifa_hora, monto_base, estado, fecha_ingreso, foto)
  values (v_id, v_nom, coalesce(p->>'apellido',''), coalesce(p->>'tipo',''), coalesce(p->>'appOrigen',''),
    coalesce(p->>'rol',''), coalesce(v_pin,''),
    case when v_pin is not null then extensions.crypt(v_pin, extensions.gen_salt('bf')) else null end,
    coalesce(p->>'color',''),
    nullif(btrim(coalesce(p->>'tarifaHora','')),'')::numeric, nullif(btrim(coalesce(p->>'montoBase','')),'')::numeric,
    v_est, now(), coalesce(p->>'foto',''))
  on conflict (id_personal) do nothing;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPersonal',v_id));
end; $fn$;

-- ── actualizar_personal: si viene pin, actualizar también pin_hash ────────────
create or replace function mos.actualizar_personal(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idPersonal','')),''); v_pin text := nullif(btrim(coalesce(p->>'pin','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;
  update mos.personal set
    nombre      = coalesce(nullif(btrim(coalesce(p->>'nombre','')),''), nombre),
    apellido    = coalesce(p->>'apellido', apellido),
    tipo        = coalesce(p->>'tipo', tipo),
    app_origen  = coalesce(p->>'appOrigen', app_origen),
    rol         = coalesce(p->>'rol', rol),
    pin         = coalesce(v_pin, pin),
    pin_hash    = case when v_pin is not null then extensions.crypt(v_pin, extensions.gen_salt('bf')) else pin_hash end,
    color       = coalesce(p->>'color', color),
    tarifa_hora = coalesce(nullif(btrim(coalesce(p->>'tarifaHora','')),'')::numeric, tarifa_hora),
    monto_base  = coalesce(nullif(btrim(coalesce(p->>'montoBase','')),'')::numeric, monto_base),
    estado      = coalesce(nullif(btrim(coalesce(p->>'estado','')),'')::boolean, estado)
   where id_personal = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','personal no encontrado'); end if;
  return jsonb_build_object('ok',true,'cambios',v_n);
end; $fn$;

-- ── crear_categoria: do nothing (no pisar existente) ──────────────────────────
create or replace function mos.crear_categoria(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_nom text := nullif(btrim(coalesce(p->>'nombre','')),'');
  v_modo text := upper(coalesce(p->>'modoVenta','MARGEN'));
  v_id text := nullif(btrim(coalesce(p->>'idCategoria','')),'');
  v_marg numeric := nullif(btrim(coalesce(p->>'margenPct','')),'')::numeric;
  v_tope numeric := nullif(btrim(coalesce(p->>'precioTope','')),'')::numeric;
  v_ya int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null then return jsonb_build_object('ok',false,'error','nombre requerido'); end if;
  if v_modo not in ('MARGEN','FIJO','COMPETITIVO','LIBRE') then return jsonb_build_object('ok',false,'error','modoVenta inválido'); end if;
  if v_modo = 'COMPETITIVO' and coalesce(v_tope,0) <= 0 then return jsonb_build_object('ok',false,'error','COMPETITIVO requiere precioTope>0'); end if;
  if v_marg is not null and (v_marg < 0 or v_marg >= 100) then return jsonb_build_object('ok',false,'error','margenPct debe estar en [0,100)'); end if;
  if v_id is null then v_id := upper(regexp_replace(v_nom,'[^A-Za-z0-9]','','g')); end if;
  select count(*) into v_ya from mos.categorias where id_categoria = v_id;
  if v_ya > 0 then return jsonb_build_object('ok',false,'error','Ya existe una categoría con id '||v_id||' — usa editar'); end if;
  insert into mos.categorias (id_categoria, nombre, modo_venta, margen_pct, precio_tope, descripcion, estado, fecha_creacion)
  values (v_id, v_nom, v_modo, v_marg, v_tope, coalesce(p->>'descripcion',''), coalesce(nullif(btrim(coalesce(p->>'estado','')),'')::boolean, true), now());
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idCategoria',v_id));
end; $fn$;

-- ── rotar_clave_admin: exigir pinAdmin de un admin real (CRÍTICO-1) ────────────
create or replace function mos.rotar_clave_admin(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_manual boolean := coalesce((p->>'manual')::boolean, true);
  v_pinadm text := nullif(btrim(coalesce(p->>'pinAdmin','')),'');
  v_por text := 'AUTO_TRIGGER';
  v_cur text; v_new text; v_try int := 0; v_now timestamptz := now();
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- [fix CRÍTICO-1] Rotación MANUAL exige el PIN de un admin real (rol MASTER/ADMIN, activo). Espejo del
  -- GAS _buscarAdminPorPin: valida contra pin_hash (bcrypt) o pin texto (legacy). Sin admin válido → autorizado:false.
  if v_manual then
    if v_pinadm is null then return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error','PIN requerido')); end if;
    select nombre into v_por from mos.personal
     where estado = true and upper(coalesce(rol,'')) in ('MASTER','ADMIN','ADMINISTRADOR')
       and ( (pin_hash is not null and pin_hash = extensions.crypt(v_pinadm, pin_hash)) or (coalesce(pin,'') = v_pinadm) )
     limit 1;
    if v_por is null then return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error','PIN no reconocido')); end if;
  end if;

  select valor into v_cur from mos.config where clave='ADMIN_GLOBAL_PIN' limit 1;
  loop
    v_try := v_try + 1;
    v_new := lpad((floor(random()*10000))::int::text, 4, '0');
    if v_new not in ('0000','1111','2222','3333','4444','5555','6666','7777','8888','9999','1234','4321','0123')
       and v_new <> coalesce(v_cur,'') then exit; end if;
    if v_try > 40 then v_new := lpad(((coalesce(v_cur,'0')::int + 7) % 10000)::text, 4, '0'); exit; end if;  -- fallback no-trivial determinista
  end loop;

  insert into mos.config(clave,valor) values
    ('ADMIN_GLOBAL_PIN', v_new),
    ('ADMIN_GLOBAL_PIN_HASH', extensions.crypt(v_new, extensions.gen_salt('bf'))),
    ('ADMIN_GLOBAL_PIN_FECHA', to_char(v_now at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'))
  on conflict (clave) do update set valor = excluded.valor;

  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'autorizado', true, 'pin', v_new, 'validadoPor', v_por,
    'fechaUltimaRotacion', to_char(v_now at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
    'fechaProximaRotacion', to_char((v_now + interval '7 days') at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS')));
end; $fn$;
