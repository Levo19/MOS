-- ════════════════════════════════════════════════════════════════════════════
-- 366 · NIVEL 1 corte-GAS (MOS admin) — RPCs de escritura sin ruta directa.
-- Espejo de las funciones GAS: setConfigMos, actualizarCostoPorSku,
-- crear/actualizarPersonalMaster, crear/actualizarZona, crearCategoria,
-- rotarClaveAdminGlobal. Gate mos._claim_ok() (token MOS). Idempotencia por
-- clave/id donde aplica. (Promociones se difiere: mos.promociones no existe aún;
-- lanzarProductoNuevo se maneja aparte por ser cross-app WH.)
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1) set_config ─────────────────────────────────────────────────────────────
create or replace function mos.set_config(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_clave text := nullif(btrim(coalesce(p->>'clave','')),''); v_val text := coalesce(p->>'valor','');
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_clave is null then return jsonb_build_object('ok',false,'error','clave requerida'); end if;
  insert into mos.config(clave,valor) values (v_clave, v_val)
  on conflict (clave) do update set valor = excluded.valor;
  return jsonb_build_object('ok',true);
end; $fn$;

-- ── 2) actualizar_costo_sku ───────────────────────────────────────────────────
create or replace function mos.actualizar_costo_sku(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_sku  text := nullif(btrim(coalesce(p->>'sku','')),'');
  v_cost numeric := nullif(btrim(coalesce(p->>'precioCosto','')),'')::numeric;
  v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sku is null or v_cost is null then return jsonb_build_object('ok',false,'error','Requiere sku y precioCosto'); end if;
  -- Prioridad: idProducto exacto → codigoBarra → skuBase canónico (factor=1).
  update mos.productos set precio_costo = v_cost, updated_at = now()
   where id_producto = v_sku;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    update mos.productos set precio_costo = v_cost, updated_at = now() where upper(btrim(codigo_barra)) = upper(v_sku);
    get diagnostics v_n = row_count;
  end if;
  if v_n = 0 then
    update mos.productos set precio_costo = v_cost, updated_at = now()
     where coalesce(nullif(btrim(sku_base),''), id_producto) = v_sku and coalesce(factor_conversion,1) = 1;
    get diagnostics v_n = row_count;
  end if;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','SKU no encontrado: '||v_sku); end if;
  return jsonb_build_object('ok',true,'filas',v_n);
end; $fn$;

-- ── 2b) actualizar_producto_master (min/max stock) — NIVEL 3 quick win ─────────
create or replace function mos.actualizar_producto_master(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_sku text := nullif(btrim(coalesce(p->>'sku', p->>'idProducto','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sku is null then return jsonb_build_object('ok',false,'error','Requiere sku/idProducto'); end if;
  update mos.productos set
    stock_minimo = coalesce(nullif(btrim(coalesce(p->>'stockMinimo','')),'')::numeric, stock_minimo),
    stock_maximo = coalesce(nullif(btrim(coalesce(p->>'stockMaximo','')),'')::numeric, stock_maximo),
    updated_at = now()
   where id_producto = v_sku or coalesce(nullif(btrim(sku_base),''), id_producto) = v_sku;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','producto no encontrado'); end if;
  return jsonb_build_object('ok',true,'filas',v_n);
end; $fn$;

-- ── 3) crear_personal / actualizar_personal ───────────────────────────────────
create or replace function mos.crear_personal(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_nom text := nullif(btrim(coalesce(p->>'nombre','')),'');
  v_id  text := nullif(btrim(coalesce(p->>'idPersonal','')),'');
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null then return jsonb_build_object('ok',false,'error','nombre requerido'); end if;
  if v_id is null then v_id := 'PER' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS') || substr(md5(random()::text),1,3); end if;
  insert into mos.personal (id_personal, nombre, apellido, tipo, app_origen, rol, pin, color,
    tarifa_hora, monto_base, estado, fecha_ingreso, foto)
  values (v_id, v_nom, coalesce(p->>'apellido',''), coalesce(p->>'tipo',''), coalesce(p->>'appOrigen',''),
    coalesce(p->>'rol',''), coalesce(p->>'pin',''), coalesce(p->>'color',''),
    nullif(btrim(coalesce(p->>'tarifaHora','')),'')::numeric, nullif(btrim(coalesce(p->>'montoBase','')),'')::numeric,
    coalesce((p->>'estado')::boolean, true), now(), coalesce(p->>'foto',''))
  on conflict (id_personal) do nothing;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPersonal',v_id));
end; $fn$;

create or replace function mos.actualizar_personal(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idPersonal','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;
  update mos.personal set
    nombre      = coalesce(nullif(btrim(coalesce(p->>'nombre','')),''), nombre),
    apellido    = coalesce(p->>'apellido', apellido),
    tipo        = coalesce(p->>'tipo', tipo),
    app_origen  = coalesce(p->>'appOrigen', app_origen),
    rol         = coalesce(p->>'rol', rol),
    pin         = coalesce(nullif(p->>'pin', null), pin),
    color       = coalesce(p->>'color', color),
    tarifa_hora = coalesce(nullif(btrim(coalesce(p->>'tarifaHora','')),'')::numeric, tarifa_hora),
    monto_base  = coalesce(nullif(btrim(coalesce(p->>'montoBase','')),'')::numeric, monto_base),
    estado      = coalesce((p->>'estado')::boolean, estado)
   where id_personal = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','personal no encontrado'); end if;
  return jsonb_build_object('ok',true,'cambios',v_n);
end; $fn$;

-- ── 4) crear_zona / actualizar_zona ───────────────────────────────────────────
create or replace function mos.crear_zona(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_nom text := nullif(btrim(coalesce(p->>'nombre','')),''); v_id text := nullif(btrim(coalesce(p->>'idZona','')),'');
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null then return jsonb_build_object('ok',false,'error','nombre requerido'); end if;
  if v_id is null then v_id := 'Z' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS'); end if;
  insert into mos.zonas (id_zona, nombre, descripcion, direccion, responsable, estado, politica_json)
  values (v_id, v_nom, coalesce(p->>'descripcion',''), coalesce(p->>'direccion',''), coalesce(p->>'responsable',''),
    coalesce(nullif(btrim(coalesce(p->>'estado','')),'')::boolean, true), coalesce(p->'politicaJSON','{}'::jsonb))
  on conflict (id_zona) do nothing;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idZona',v_id));
end; $fn$;

create or replace function mos.actualizar_zona(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idZona','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idZona requerido'); end if;
  update mos.zonas set
    nombre       = coalesce(nullif(btrim(coalesce(p->>'nombre','')),''), nombre),
    descripcion  = coalesce(p->>'descripcion', descripcion),
    direccion    = coalesce(p->>'direccion', direccion),
    responsable  = coalesce(p->>'responsable', responsable),
    estado       = coalesce(nullif(btrim(coalesce(p->>'estado','')),'')::boolean, estado),
    politica_json= coalesce(p->'politicaJSON', politica_json)
   where id_zona = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','zona no encontrada'); end if;
  return jsonb_build_object('ok',true);
end; $fn$;

-- ── 5) crear_categoria ────────────────────────────────────────────────────────
create or replace function mos.crear_categoria(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_nom text := nullif(btrim(coalesce(p->>'nombre','')),'');
  v_modo text := upper(coalesce(p->>'modoVenta','MARGEN'));
  v_id text := nullif(btrim(coalesce(p->>'idCategoria','')),'');
  v_marg numeric := nullif(btrim(coalesce(p->>'margenPct','')),'')::numeric;
  v_tope numeric := nullif(btrim(coalesce(p->>'precioTope','')),'')::numeric;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null then return jsonb_build_object('ok',false,'error','nombre requerido'); end if;
  if v_modo not in ('MARGEN','FIJO','COMPETITIVO','LIBRE') then return jsonb_build_object('ok',false,'error','modoVenta inválido'); end if;
  if v_modo = 'COMPETITIVO' and coalesce(v_tope,0) <= 0 then return jsonb_build_object('ok',false,'error','COMPETITIVO requiere precioTope>0'); end if;
  if v_marg is not null and (v_marg < 0 or v_marg >= 100) then return jsonb_build_object('ok',false,'error','margenPct debe estar en [0,100)'); end if;
  if v_id is null then v_id := upper(regexp_replace(v_nom,'[^A-Za-z0-9]','','g')); end if;
  insert into mos.categorias (id_categoria, nombre, modo_venta, margen_pct, precio_tope, descripcion, estado, fecha_creacion)
  values (v_id, v_nom, v_modo, v_marg, v_tope, coalesce(p->>'descripcion',''), coalesce(nullif(btrim(coalesce(p->>'estado','')),'')::boolean, true), now())
  on conflict (id_categoria) do update set nombre=excluded.nombre, modo_venta=excluded.modo_venta,
    margen_pct=excluded.margen_pct, precio_tope=excluded.precio_tope, descripcion=excluded.descripcion, estado=excluded.estado;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idCategoria',v_id));
end; $fn$;

-- ── 6) rotar_clave_admin ──────────────────────────────────────────────────────
-- Genera un PIN de 4 díg no-trivial y distinto al actual; setea ADMIN_GLOBAL_PIN (texto),
-- ADMIN_GLOBAL_PIN_HASH (bcrypt, que es lo que valida verificar_clave_admin) y la fecha.
create or replace function mos.rotar_clave_admin(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_cur text; v_new text; v_try int := 0; v_now timestamptz := now();
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select valor into v_cur from mos.config where clave='ADMIN_GLOBAL_PIN' limit 1;
  loop
    v_new := lpad((floor(random()*10000))::int::text, 4, '0');
    v_try := v_try + 1;
    exit when v_try > 40;
    continue when v_new in ('0000','1111','2222','3333','4444','5555','6666','7777','8888','9999','1234','4321','0123');
    continue when v_new = coalesce(v_cur,'');
    exit;
  end loop;
  insert into mos.config(clave,valor) values
    ('ADMIN_GLOBAL_PIN', v_new),
    ('ADMIN_GLOBAL_PIN_HASH', extensions.crypt(v_new, extensions.gen_salt('bf'))),
    ('ADMIN_GLOBAL_PIN_FECHA', to_char(v_now at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'))
  on conflict (clave) do update set valor = excluded.valor;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'autorizado', true, 'pin', v_new,
    'fechaUltimaRotacion', to_char(v_now at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
    'fechaProximaRotacion', to_char((v_now + interval '7 days') at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS')));
end; $fn$;

revoke all on function mos.set_config(jsonb), mos.actualizar_costo_sku(jsonb), mos.actualizar_producto_master(jsonb),
  mos.crear_personal(jsonb), mos.actualizar_personal(jsonb), mos.crear_zona(jsonb), mos.actualizar_zona(jsonb),
  mos.crear_categoria(jsonb), mos.rotar_clave_admin(jsonb) from public, anon;
grant execute on function mos.set_config(jsonb), mos.actualizar_costo_sku(jsonb), mos.actualizar_producto_master(jsonb),
  mos.crear_personal(jsonb), mos.actualizar_personal(jsonb), mos.crear_zona(jsonb), mos.actualizar_zona(jsonb),
  mos.crear_categoria(jsonb), mos.rotar_clave_admin(jsonb) to authenticated, service_role;
