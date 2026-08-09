-- ════════════════════════════════════════════════════════════════════
-- 724 — DOCTRINA DE COSTOS Y PRECIOS DEL DUEÑO (cierre en la base de datos)
--
-- DIRECTRIZ LITERAL:
--   "los únicos que ponen costo del producto son MOS, donde admin y master viven,
--    y se deben guardar en la tabla de costos; lo mismo con los precios: solo MOS
--    puede setear precios y también tienen histórico. Las zonas (ME y WH) solo
--    hacen registro; en MOS se verifica."
--
-- DE DÓNDE VIENE (auditoría previa + SQL 722):
--   · Las 11 funciones que tocan precio_costo/precio_venta/segmentos viven TODAS en
--     el esquema `mos`. Cero en `me`/`wh` → la mitad "solo MOS" ya estaba estructural.
--   · 722 revocó anon/public en las 7 escritoras. Faltaban dos cosas: QUIÉN (rol) y
--     RASTRO (histórico) en las vías que escribían dinero a ciegas.
--
-- LO QUE ESTE SCRIPT AGREGA
--   A) mos._rol_precio_ok(text)  — helper de rol (ADMIN/MASTER activo, o ascendido
--      acceso_mos, igual que mos._validar_clave_admin_core) + lista blanca por config.
--   B) GUARD DE ROL → {ok:false, error:'ROL_NO_AUTORIZADO'} sin escribir nada, en:
--      aplicar_costos_compra · quitar_costo_compra · crear_producto ·
--      actualizar_segmentos_precio · actualizar_producto (SOLO si el patch trae
--      precioVenta/precioCosto) · actualizar_costo_sku (TOLERANTE al usuario vacío,
--      ver nota abajo).
--   C) HISTÓRICO en mos.historial_precio_costo donde no lo había:
--      actualizar_costo_sku → source 'MOS_COSTO_SKU'
--      quitar_costo_compra  → source 'COMPRA_REVERSA'   (la reversa no dejaba rastro)
--      aplicar_respuesta_jefa (rama COSTO) → source 'JEFA'
--      actualizar_producto (precioCosto)   → source 'MOS_CATALOGO'
--      crear_producto (costo inicial)      → source 'ALTA_PRODUCTO'
--      actualizar_segmentos_precio → tipo 'TRAMOS', source 'SEGMENTOS' (meta lleva
--      el arreglo de tramos ANTES y DESPUÉS: auditoría reversible).
--      TODOS los inserts son best-effort (begin/exception/null): un fallo de log
--      JAMÁS revierte la escritura de dinero — mismo criterio que ya usaba
--      aplicar_costos_compra desde [576].
--
-- MEDICIÓN CONTRA DATOS REALES ANTES DE APLICAR (60 días, cruzada con mos.personal):
--   Javier (ADMIN)  → 107 costos COMPRA · 15 precios · 103 historial_precios · 504 historial_cambios · 2 tramos  → PASA
--   Luis   (MASTER) →  11 costos COMPRA · 19 precios · 169 historial_precios ·  17 historial_cambios · 5 tramos  → PASA
--   NO pasan (los 3 son ruido, NO operación): 'PRUEBA CLAUDE' (2, dato de prueba de
--   un agente), 'admin' (1 fila 'seg-test' del 26/06) y 'Claude (limpieza de dato de
--   prueba)' (1). CERO procesos automáticos escribiendo costos/precios ⇒ la lista
--   blanca mos.config['COSTO_PRECIO_USUARIOS_EXTRA'] nace VACÍA (existe como palanca).
--
-- POR QUÉ actualizar_costo_sku LLEVA GUARD TOLERANTE (no romper producción):
--   js/api.js manda el payload CRUDO por _MOS_ADMIN_RPC y los dos call-sites de
--   app.js (finGuardarCostoProd:38601, promoGuardarCostoRapido:40907) NO incluyen
--   'usuario'. Un guard duro habría roto el 100% de esa vía en clientes con SW
--   cacheado. Se agregó la inyección de usuario en api.js (_mosUsuario) y el guard
--   rechaza SIEMPRE un usuario presente-y-no-autorizado, pero deja pasar el vacío.
--   ENDURECER (una vez desplegado el front en todos los dispositivos): borrar el
--   `v_usr <> '' and` de la condición dentro de mos.actualizar_costo_sku.
--
-- POR QUÉ actualizar_producto LLEVA GUARD QUIRÚRGICO:
--   es el editor GENERAL del catálogo (descripción, categoría, unidad, factores,
--   stock mín/máx). Bloquearla entera por rol rompería la edición NO monetaria.
--   El guard sólo se dispara si el patch trae precioVenta o precioCosto.
--
-- LO QUE NO SE TOCA
--   · mos._claim_ok(): sigue siendo `me.jwt_app() in ('','MOS')` — el claim VACÍO
--     (anon key) todavía pasa. Endurecerlo cambia TODAS las RPCs mos.* de golpe →
--     queda para su propia ventana, como ya decía 722. Con 722 (revoke anon/public)
--     + este 724 (rol) el riesgo residual de esa puerta quedó muy acotado.
--   · mos.aplicar_respuesta_jefa NO recibe guard de rol: ya exige clave admin y
--     mos._validar_clave_admin_core exige rol_nivel>=2 (ADMIN/MASTER) o acceso_mos
--     — exactamente el mismo predicado que _rol_precio_ok. Sólo se le agregó rastro.
--   · mos.publicar_precio: intacta. Ver BUG PREEXISTENTE al final del archivo.
-- ════════════════════════════════════════════════════════════════════

-- ── helper de rol para la doctrina de costos/precios ──────────────────────
-- Verdadero si `p_usuario` corresponde a alguien de mos.personal ACTIVO con
-- rol ADMIN/MASTER (rol_nivel>=2) O ascendido (acceso_mos=true, que es como el
-- resto del sistema ya trata al ascendido: mos._validar_clave_admin_core lo
-- promueve a 'ADMIN'). Match tolerante porque los payloads traen el nombre en
-- 3 formas distintas: 'Luis' (front _mosUsuario/S.session.nombre), 'Luis Vasquez'
-- (verificar_clave_admin devuelve nombre||' '||apellido) y eventualmente id_personal.
-- Lista blanca operativa: mos.config['COSTO_PRECIO_USUARIOS_EXTRA'] (CSV) para
-- procesos automáticos futuros SIN necesidad de migración. Hoy nace VACÍA porque
-- la medición de 60 días no encontró NINGÚN escritor automático.
create or replace function mos._rol_precio_ok(p_usuario text)
 returns boolean
 language sql
 stable
 security definer
 set search_path to ''
as $function$
  select case when btrim(coalesce(p_usuario,'')) = '' then false else (
    exists (
      select 1 from mos.personal pe
       where coalesce(pe.estado, true)
         and (mos.rol_nivel(pe.rol) >= 2 or coalesce(pe.acceso_mos, false))
         and (
              upper(regexp_replace(btrim(coalesce(pe.nombre,'')), '[[:space:]]+', ' ', 'g'))
                = upper(regexp_replace(btrim(p_usuario), '[[:space:]]+', ' ', 'g'))
           or upper(regexp_replace(btrim(coalesce(pe.nombre,'') || ' ' || coalesce(pe.apellido,'')), '[[:space:]]+', ' ', 'g'))
                = upper(regexp_replace(btrim(p_usuario), '[[:space:]]+', ' ', 'g'))
           or upper(btrim(coalesce(pe.id_personal,''))) = upper(btrim(p_usuario))
         )
    )
    or exists (
      select 1 from mos.config c
       cross join lateral unnest(string_to_array(coalesce(c.valor,''), ',')) w(x)
       where c.clave = 'COSTO_PRECIO_USUARIOS_EXTRA'
         and btrim(w.x) <> ''
         and upper(regexp_replace(btrim(w.x), '[[:space:]]+', ' ', 'g'))
             = upper(regexp_replace(btrim(p_usuario), '[[:space:]]+', ' ', 'g'))
    )
  ) end;
$function$;

revoke execute on function mos._rol_precio_ok(text) from public, anon;

-- ── palanca de lista blanca (nace vacía; CSV de nombres) ────────────────
insert into mos.config (clave, valor) values ('COSTO_PRECIO_USUARIOS_EXTRA','')
on conflict (clave) do nothing;

-- ══════════════════════════════════════════════════════════════════
-- mos.actualizar_costo_sku
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION mos.actualizar_costo_sku(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_sku  text := nullif(btrim(coalesce(p->>'sku','')),'');
  v_cost numeric := nullif(btrim(coalesce(p->>'precioCosto','')),'')::numeric;
  v_n int;
  -- [724] doctrina costos: identidad + foto PREVIA para dejar rastro en la tabla de costos.
  v_usr  text := btrim(coalesce(p->>'usuario',''));
  v_pre  jsonb := '[]'::jsonb;
  v_e    jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- [724] GUARD DE ROL (doctrina: solo ADMIN/MASTER de MOS ponen costo). TOLERANTE al usuario VACIO
  -- a proposito: el front hoy llama actualizarCostoPorSku SIN 'usuario' (api.js _MOS_ADMIN_RPC manda p crudo)
  -- y bloquear el vacio romperia Finanzas/Promos en clientes con SW cacheado. Se endurece a `not mos._rol_precio_ok(v_usr)`
  -- (sin el `v_usr <> ''`) cuando el front que SI manda usuario este desplegado en todos los dispositivos.
  if v_usr <> '' and not mos._rol_precio_ok(v_usr) then return jsonb_build_object('ok',false,'error','ROL_NO_AUTORIZADO'); end if;
  if v_sku is null or v_cost is null then return jsonb_build_object('ok',false,'error','Requiere sku y precioCosto'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id_producto, 'sku', coalesce(nullif(btrim(t.sku_base),''), t.id_producto), 'prev', t.precio_costo)), '[]'::jsonb)
    into v_pre from mos.productos t where t.id_producto = v_sku;
  update mos.productos set precio_costo = v_cost, updated_at = now() where id_producto = v_sku;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    select coalesce(jsonb_agg(jsonb_build_object('id', t.id_producto, 'sku', coalesce(nullif(btrim(t.sku_base),''), t.id_producto), 'prev', t.precio_costo)), '[]'::jsonb)
      into v_pre from mos.productos t where upper(btrim(t.codigo_barra)) = upper(v_sku);
    update mos.productos set precio_costo = v_cost, updated_at = now() where upper(btrim(codigo_barra)) = upper(v_sku);
    get diagnostics v_n = row_count;
  end if;
  if v_n = 0 then
    -- [fix MEDIO-1] canónico por skuBase; si es AMBIGUO (>1 fila) NO commitear a ciegas.
    select count(*) into v_n from mos.productos
     where coalesce(nullif(btrim(sku_base),''), id_producto) = v_sku and coalesce(factor_conversion,1) = 1;
    if v_n > 1 then return jsonb_build_object('ok',false,'error','skuBase ambiguo ('||v_n||' filas) — usa idProducto'); end if;
    select coalesce(jsonb_agg(jsonb_build_object('id', t.id_producto, 'sku', coalesce(nullif(btrim(t.sku_base),''), t.id_producto), 'prev', t.precio_costo)), '[]'::jsonb)
      into v_pre from mos.productos t
     where coalesce(nullif(btrim(t.sku_base),''), t.id_producto) = v_sku and coalesce(t.factor_conversion,1) = 1;
    update mos.productos set precio_costo = v_cost, updated_at = now()
     where coalesce(nullif(btrim(sku_base),''), id_producto) = v_sku and coalesce(factor_conversion,1) = 1;
    get diagnostics v_n = row_count;
  end if;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','SKU no encontrado: '||v_sku); end if;
  -- [724] HISTORIAL DE COSTO en la tabla de costos (antes esta via NO dejaba rastro alguno).
  -- source='MOS_COSTO_SKU' = edicion directa de costo desde MOS (Finanzas / Promos), sin guia de compra.
  -- Best-effort: un fallo de log JAMAS rompe la escritura del costo (mismo criterio que aplicar_costos_compra).
  begin
    for v_e in select * from jsonb_array_elements(v_pre) loop
      if mos._numn(v_e->>'prev') is distinct from v_cost then
        insert into mos.historial_precio_costo(id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, app_origen, ts, meta)
        values (v_e->>'id', v_e->>'sku', 'COSTO', v_cost, mos._numn(v_e->>'prev'),
                nullif(v_usr,''), 'MOS_COSTO_SKU', 'MOS', now(),
                jsonb_build_object('skuPedido', v_sku, 'filas', v_n));
      end if;
    end loop;
  exception when others then null;
  end;
  return jsonb_build_object('ok',true,'filas',v_n);
end; $function$

;

-- ══════════════════════════════════════════════════════════════════
-- mos.actualizar_segmentos_precio
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION mos.actualizar_segmentos_precio(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_sku   text := nullif(btrim(coalesce(p->>'skuBase', p->>'sku_base','')), '');
  v_id    text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_segs  jsonb := coalesce(p->'segmentos', '[]'::jsonb);
  v_val   jsonb; v_limpios jsonb; v_canon record;
  -- [724] doctrina precios: identidad del actor + foto PREVIA de los tramos para el historico.
  v_usr   text := btrim(coalesce(p->>'usuario',''));
  v_ant   jsonb;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- [724] GUARD DE ROL: los tramos SON precio (ajustePct sobre el precio del canonico) → solo ADMIN/MASTER.
  -- El front SIEMPRE manda usuario (api.js actualizarSegmentosPrecio: usuario:_mosUsuario(p)) → guard DURO.
  if not mos._rol_precio_ok(v_usr) then return jsonb_build_object('ok',false,'error','ROL_NO_AUTORIZADO'); end if;
  if v_sku is null and v_id is not null then
    select sku_base into v_sku from mos.productos where id_producto = v_id limit 1;
  end if;
  if v_sku is null then return jsonb_build_object('ok',false,'error','skuBase requerido'); end if;

  v_val := mos._validar_segmentos_precio(v_segs);
  if not (v_val->>'ok')::boolean then return v_val; end if;
  v_limpios := v_val->'segmentos';

  -- el grupo debe tener un canónico KGM (los tramos son volumétricos, solo para graneles)
  select * into v_canon from mos.productos
   where sku_base = v_sku and coalesce(nullif(factor_conversion,0),1)=1
   order by (upper(coalesce(unidad_medida,''))='KGM') desc nulls last limit 1;
  if not found then return jsonb_build_object('ok',false,'error','sku_base sin canónico: '||v_sku); end if;
  if upper(coalesce(v_canon.unidad_medida,'')) <> 'KGM' then
    return jsonb_build_object('ok',false,'error','Solo grupos KGM (granel) admiten tramos · este es '||coalesce(nullif(upper(v_canon.unidad_medida),''),'sin unidad'));
  end if;

  select pt.tramos into v_ant from mos.precio_tramos pt where pt.sku_base = v_sku;

  if jsonb_array_length(v_limpios) = 0 then
    delete from mos.precio_tramos where sku_base = v_sku;   -- vaciar = borrar el grupo
  else
    insert into mos.precio_tramos (sku_base, tramos, updated_at, updated_by)
    values (v_sku, v_limpios, now(), coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'admin'))
    on conflict (sku_base) do update set tramos=excluded.tramos, updated_at=now(), updated_by=excluded.updated_by;
  end if;

  -- [724] HISTORIAL de TRAMOS (antes esta via NO dejaba rastro). Va a mos.historial_precio_costo porque es la
  -- tabla de historico de dinero con `meta` jsonb (mos.historial_precios solo admite un escalar anterior/nuevo
  -- y un tramo NO es un escalar: es un arreglo de %ajuste por volumen). tipo='TRAMOS' (nuevo, no perturba a los
  -- consumidores que filtran tipo in ('COSTO','PRECIO')); valor = nº de tramos vigentes (0 = borrado del grupo),
  -- valor_anterior = nº de tramos previos; el detalle COMPLETO (antes/despues) queda en meta → auditoria reversible.
  begin
    if coalesce(v_ant,'[]'::jsonb) is distinct from coalesce(v_limpios,'[]'::jsonb) then
      insert into mos.historial_precio_costo(id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, app_origen, ts, meta)
      values (v_canon.id_producto, v_sku, 'TRAMOS',
              jsonb_array_length(coalesce(v_limpios,'[]'::jsonb)), jsonb_array_length(coalesce(v_ant,'[]'::jsonb)),
              nullif(v_usr,''), 'SEGMENTOS', 'MOS', now(),
              jsonb_build_object('descripcion', coalesce(v_canon.descripcion,''),
                                 'tramosAnterior', coalesce(v_ant,'[]'::jsonb),
                                 'tramosNuevo', coalesce(v_limpios,'[]'::jsonb)));
    end if;
  exception when others then null;
  end;

  return jsonb_build_object('ok', true, 'skuBase', v_sku, 'segmentos', v_limpios, 'total', jsonb_array_length(v_limpios));
end;$function$

;

-- ══════════════════════════════════════════════════════════════════
-- mos.aplicar_respuesta_jefa
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION mos.aplicar_respuesta_jefa(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_g     text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_clave text := coalesce(p->>'claveAdmin','');
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_verif jsonb; v_por text;
  v_it jsonb; v_sku text; v_vn numeric; v_mg numeric; v_cn numeric;
  v_costo numeric; v_venta numeric; v_res jsonb; rd jsonb;
  v_aplic int := 0; v_err jsonb := '[]'::jsonb; v_cambios jsonb := '[]'::jsonb;
  -- [724] foto PREVIA del costo canonico para poder registrar valor_anterior en el historico.
  v_cid text; v_cprev numeric;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if jsonb_typeof(v_items) <> 'array' then return jsonb_build_object('ok',false,'error','items debe ser array'); end if;
  v_verif := mos.verificar_clave_admin(v_clave, 'APLICAR_RESPUESTA_JEFA', coalesce(v_g,''), 'MOS', '', 'Respuesta jefa');
  if not coalesce((v_verif->>'autorizado')::boolean,false) then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error',coalesce(v_verif->>'error','Clave incorrecta')));
  end if;
  v_por := coalesce(nullif(btrim(coalesce(v_verif->>'nombre','')),''),'admin');

  for v_it in select * from jsonb_array_elements(v_items) loop
    v_sku := nullif(btrim(coalesce(v_it->>'skuBase','')),'');
    v_vn  := mos._numn(v_it->>'ventaNueva');
    v_mg  := mos._numn(v_it->>'margenNuevoPct');
    v_cn  := mos._numn(v_it->>'costoNuevo');
    if v_sku is null then continue; end if;
    if v_vn is null and v_mg is null then continue; end if;
    if v_cn is not null and v_cn > 0 then v_costo := v_cn;
    else select precio_costo into v_costo from mos.productos
          where coalesce(nullif(btrim(sku_base),''), id_producto) = v_sku
          order by (coalesce(factor_conversion,1)=1 and btrim(coalesce(codigo_producto_base,''))='') desc limit 1;
    end if;
    v_costo := coalesce(v_costo,0);
    if v_vn is not null and v_vn > 0 then v_venta := round(v_vn, 2);
    elsif v_mg is not null and v_mg > -0.5 and v_mg < 0.99 and v_costo > 0 then v_venta := round(v_costo / (1 - v_mg), 2);
    else
      v_err := v_err || jsonb_build_object('skuBase',v_sku,'error','datos insuficientes (venta/margen inválido o sin costo)');
      continue;
    end if;

    -- [FIX 393] aplicar la VENTA primero; solo si ok, tocar el COSTO (evita catálogo con costo nuevo + venta vieja).
    v_res := mos.publicar_precio(jsonb_build_object('skuBase', v_sku, 'precioNuevo', v_venta,
      'motivo', 'Respuesta jefa · guía '||coalesce(v_g,''), 'usuario', v_por));
    if coalesce((v_res->>'ok')::boolean,false) then
      if v_cn is not null and v_cn > 0 then
        -- [724] identificar el canonico y su costo ANTERIOR antes de pisarlo (mismo predicado del UPDATE).
        v_cid := null; v_cprev := null;
        begin
          select pr.id_producto, pr.precio_costo into v_cid, v_cprev from mos.productos pr
           where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = v_sku
             and coalesce(pr.factor_conversion,1) = 1 and btrim(coalesce(pr.codigo_producto_base,'')) = ''
           limit 1;
        exception when others then null;
        end;
        update mos.productos set precio_costo = v_cn, updated_at = now()
         where coalesce(nullif(btrim(sku_base),''), id_producto) = v_sku
           and coalesce(factor_conversion,1) = 1 and btrim(coalesce(codigo_producto_base,'')) = '';
        -- [724] HISTORIAL DE COSTO (antes esta via pisaba precio_costo SIN dejar rastro; solo la VENTA quedaba
        -- registrada, via mos.publicar_precio). source='JEFA' = costo autorizado por la jefa con clave admin.
        -- Best-effort: un fallo de log JAMAS revierte el costo ya aplicado.
        begin
          if v_cid is not null and (v_cprev is distinct from v_cn) then
            insert into mos.historial_precio_costo(id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, app_origen, id_guia, ts, meta)
            values (v_cid, v_sku, 'COSTO', v_cn, v_cprev, v_por, 'JEFA', 'MOS', coalesce(v_g,''), now(),
                    jsonb_build_object('ventaAplicada', v_venta, 'motivo', 'Respuesta jefa'));
          end if;
        exception when others then null;
        end;
      end if;
      rd := coalesce(v_res->'data','{}'::jsonb);
      v_aplic := v_aplic + 1;
      v_cambios := v_cambios || jsonb_build_object('skuBase', v_sku, 'descripcion', rd->>'descripcion',
        'ventaAnterior', rd->>'precioAnterior', 'ventaNueva', v_venta, 'costo', v_costo,
        'presentaciones', coalesce((rd->>'presentacionesActualizadas')::int,0));
    else
      v_err := v_err || jsonb_build_object('skuBase',v_sku,'error',coalesce(v_res->>'error','publicar_precio falló'));
    end if;
  end loop;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'autorizado', true, 'aplicados', v_aplic, 'errores', v_err, 'cambios', v_cambios,
    'autorizadoPor', v_por, 'ticketImpreso', false));
end; $function$

;

-- ══════════════════════════════════════════════════════════════════
-- mos.aplicar_costos_compra
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION mos.aplicar_costos_compra(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_guia text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_usr  text := coalesce(p->>'usuario','');
  v_guia_fecha timestamptz;
  it jsonb; v_cb text; v_costo numeric;
  v_prod record; v_canon record;
  v_factor numeric; v_costo_canon numeric; v_prev numeric;
  v_out jsonb := '[]'::jsonb;
  v_hist jsonb;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- [724] GUARD DE ROL (doctrina: el costo lo pone MOS, donde viven admin y master).
  -- Guard DURO: la medicion de 60 dias muestra que TODAS las escrituras reales de esta via traen
  -- usuario = 'Javier' (ADMIN, 107) o 'Luis' (MASTER, 11); no hay procesos automaticos.
  if not mos._rol_precio_ok(v_usr) then return jsonb_build_object('ok',false,'error','ROL_NO_AUTORIZADO'); end if;
  if jsonb_typeof(p->'items') <> 'array' then
    return jsonb_build_object('ok',false,'error','Requiere items[]');
  end if;

  -- [576] fecha de ORIGEN del costo = fecha de la GUÍA (no la de registro). Fallback: now.
  if v_guia is not null then
    begin select g.fecha into v_guia_fecha from wh.guias g where g.id_guia = v_guia limit 1;
    exception when others then v_guia_fecha := null; end;
  end if;
  v_guia_fecha := coalesce(v_guia_fecha, now());

  for it in select * from jsonb_array_elements(p->'items') loop
    v_cb    := upper(btrim(coalesce(it->>'codProducto', it->>'codigoBarra','')));
    v_costo := mos._numn(it->>'costoUnitario');
    if v_cb = '' or v_costo is null or v_costo <= 0 then continue; end if;

    select pr.* into v_prod from mos.productos pr
     where upper(btrim(coalesce(pr.codigo_barra,''))) = v_cb limit 1;
    if v_prod.id_producto is null then
      select pr.* into v_prod from mos.productos pr
       join mos.equivalencias e on e.activo and upper(btrim(e.codigo_barra)) = v_cb
        and pr.sku_base = e.sku_base and coalesce(nullif(pr.factor_conversion,0),1) = 1
       limit 1;
    end if;
    if v_prod.id_producto is null then
      v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', false, 'error', 'NO_EN_CATALOGO');
      continue;
    end if;

    select pr.* into v_canon from mos.productos pr
     where (pr.sku_base = coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto)
            or pr.id_producto = coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto))
       and coalesce(nullif(pr.factor_conversion,0),1) = 1
       and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = ''
     order by pr.codigo_barra limit 1;
    if v_canon.id_producto is null then v_canon := v_prod; end if;

    v_factor := case
      when coalesce(nullif(btrim(v_prod.codigo_producto_base),''),'') <> ''
           and coalesce(v_prod.factor_conversion_base,0) > 0 then v_prod.factor_conversion_base
      when coalesce(nullif(v_prod.factor_conversion,0),1) <> 1 then v_prod.factor_conversion
      else 1 end;
    v_costo_canon := round(v_costo / nullif(v_factor,0), 4);
    v_prev := v_canon.precio_costo;

    -- historial_cambios (jsonb, cap 50) — se mantiene para consumidores existentes; ts = fecha guía.
    v_hist := jsonb_build_object('ts', to_char(v_guia_fecha at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
      'accion','COSTO', 'usuario', v_usr, 'source','COMPRA', 'idGuia', coalesce(v_guia,''),
      'costoAnterior', v_prev, 'precioCosto', v_costo_canon,
      'compradoComo', v_prod.descripcion, 'factorAplicado', v_factor);
    update mos.productos
       set precio_costo = v_costo_canon,
           historial_cambios = case
             when jsonb_array_length(coalesce(historial_cambios,'[]'::jsonb)) >= 50 then
               (select jsonb_agg(e order by ord)
                  from jsonb_array_elements(coalesce(historial_cambios,'[]'::jsonb) || v_hist)
                       with ordinality x(e, ord)
                 where ord > 1)
             else coalesce(historial_cambios,'[]'::jsonb) || v_hist
           end
     where id_producto = v_canon.id_producto;

    -- [576] HISTORIAL de COSTO en tabla (fuente de la analítica). sku_base = grupo del canónico.
    -- Best-effort: un fallo de log NO rompe la aplicación del costo.
    begin
      insert into mos.historial_precio_costo(id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, id_guia, ts, meta)
      values (v_canon.id_producto, coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto),
              'COSTO', v_costo_canon, v_prev, v_usr, 'COMPRA', coalesce(v_guia,''), v_guia_fecha,
              jsonb_build_object('compradoComo', v_prod.descripcion, 'factorAplicado', v_factor));
    exception when others then null;
    end;

    v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', true,
      'idCanonico', v_canon.id_producto, 'skuBase', coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto),
      'descripcion', v_canon.descripcion, 'costoAnterior', v_prev, 'costoNuevo', v_costo_canon);
  end loop;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object('items', v_out));
end; $function$

;

-- ══════════════════════════════════════════════════════════════════
-- mos.quitar_costo_compra
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION mos.quitar_costo_compra(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_guia text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_usr  text := coalesce(p->>'usuario','');
  it jsonb; v_cb text;
  v_prod record; v_canon record;
  v_restore numeric; v_prev numeric; v_n int;
  v_out jsonb := '[]'::jsonb; v_hist jsonb; v_nuevo_hist jsonb;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- [724] GUARD DE ROL (doctrina): revertir un costo ES poner un costo → solo ADMIN/MASTER de MOS.
  if not mos._rol_precio_ok(v_usr) then return jsonb_build_object('ok',false,'error','ROL_NO_AUTORIZADO'); end if;
  if v_guia is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;
  if jsonb_typeof(p->'items') <> 'array' then return jsonb_build_object('ok',false,'error','Requiere items[]'); end if;

  for it in select * from jsonb_array_elements(p->'items') loop
    v_cb := upper(btrim(coalesce(it->>'codProducto', it->>'codigoBarra','')));
    if v_cb = '' then continue; end if;

    -- localizar producto (cb directo o equivalencia) y su canónico (misma lógica que aplicar_costos_compra)
    select pr.* into v_prod from mos.productos pr where upper(btrim(coalesce(pr.codigo_barra,''))) = v_cb limit 1;
    if v_prod.id_producto is null then
      select pr.* into v_prod from mos.productos pr
       join mos.equivalencias e on e.activo and upper(btrim(e.codigo_barra)) = v_cb
        and pr.sku_base = e.sku_base and coalesce(nullif(pr.factor_conversion,0),1) = 1 limit 1;
    end if;
    if v_prod.id_producto is null then
      v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', false, 'error', 'NO_EN_CATALOGO'); continue;
    end if;
    select pr.* into v_canon from mos.productos pr
     where (pr.sku_base = coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto)
            or pr.id_producto = coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto))
       and coalesce(nullif(pr.factor_conversion,0),1) = 1
       and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = ''
     order by pr.codigo_barra limit 1;
    if v_canon.id_producto is null then v_canon := v_prod; end if;

    v_prev := v_canon.precio_costo;

    -- valor a restaurar = costoAnterior de la entrada COSTO·COMPRA MÁS ANTIGUA de esta guía.
    -- (si no hay entrada de esta guía, no hay nada que deshacer → dejamos el costo tal cual.)
    select (e->>'costoAnterior')::numeric into v_restore
      from mos.productos pr, jsonb_array_elements(coalesce(pr.historial_cambios,'[]'::jsonb)) e
     where pr.id_producto = v_canon.id_producto
       and upper(coalesce(e->>'accion','')) = 'COSTO'
       and upper(coalesce(e->>'source','')) = 'COMPRA'
       and coalesce(e->>'idGuia','') = v_guia
     order by e->>'ts' asc
     limit 1;

    if v_restore is null then
      v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', true, 'sinCambio', true,
        'idCanonico', v_canon.id_producto, 'costoActual', v_prev);
      continue;
    end if;

    -- historial nuevo = quitar TODAS las entradas COSTO·COMPRA de esta guía + marcador REVERTIDO
    v_hist := jsonb_build_object('ts', to_char(now() at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
      'accion','COSTO_REVERTIDO', 'usuario', v_usr, 'source','COMPRA', 'idGuia', v_guia,
      'costoAnterior', v_prev, 'precioCosto', v_restore, 'compradoComo', v_canon.descripcion);
    select coalesce(jsonb_agg(e order by ord), '[]'::jsonb) into v_nuevo_hist
      from mos.productos pr, jsonb_array_elements(coalesce(pr.historial_cambios,'[]'::jsonb)) with ordinality x(e,ord)
     where pr.id_producto = v_canon.id_producto
       and not (upper(coalesce(e->>'accion','')) = 'COSTO'
                and upper(coalesce(e->>'source','')) = 'COMPRA'
                and coalesce(e->>'idGuia','') = v_guia);

    update mos.productos
       set precio_costo = v_restore,
           historial_cambios = case
             when jsonb_array_length(v_nuevo_hist || v_hist) >= 50 then
               (select jsonb_agg(e order by ord) from jsonb_array_elements(v_nuevo_hist || v_hist)
                  with ordinality x(e, ord) where ord > 1)
             else v_nuevo_hist || v_hist end,
           updated_at = now()
     where id_producto = v_canon.id_producto;
    get diagnostics v_n = row_count;
    -- [724] la REVERSA tambien va a la TABLA de costos (antes solo quedaba en productos.historial_cambios,
    -- por lo que la analitica que lee mos.historial_precio_costo veia el costo aplicado pero NUNCA su reversa).
    begin
      if v_n > 0 and (v_prev is distinct from v_restore) then
        insert into mos.historial_precio_costo(id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, app_origen, id_guia, ts, meta)
        values (v_canon.id_producto, coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto),
                'COSTO', v_restore, v_prev, nullif(v_usr,''), 'COMPRA_REVERSA', 'MOS', v_guia, now(),
                jsonb_build_object('descripcion', coalesce(v_canon.descripcion,''), 'accion', 'COSTO_REVERTIDO'));
      end if;
    exception when others then null;
    end;

    v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', (v_n > 0),
      'idCanonico', v_canon.id_producto, 'skuBase', coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto),
      'descripcion', v_canon.descripcion, 'costoAnterior', v_prev, 'costoRestaurado', v_restore);
  end loop;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object('items', v_out));
end; $function$

;

-- ══════════════════════════════════════════════════════════════════
-- mos.actualizar_producto
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION mos.actualizar_producto(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id       text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_codmatch text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_row      record;
  v_pv_new   numeric;
  v_pv_old   numeric;
  v_cambio_precio boolean := false;
  v_pres_upd int := 0;
  v_unidad   text := nullif(btrim(coalesce(p->>'unidad','')),'');
  v_unidadm  text := nullif(btrim(coalesce(p->>'Unidad_Medida','')),'');
  v_es_canon boolean;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- [724] GUARD DE ROL QUIRURGICO: esta RPC es el editor GENERAL del catalogo (descripcion, categoria,
  -- unidad, factores, stock min/max...). Bloquearla entera por rol romperia la edicion NO monetaria a los
  -- operadores ascendidos (acceso_mos). Por eso el guard SOLO se dispara cuando el patch trae dinero:
  -- precioVenta o precioCosto. Doctrina: el precio y el costo los pone MOS, admin/master.
  if ((p ? 'precioVenta') or (p ? 'precioCosto'))
     and not mos._rol_precio_ok(coalesce(p->>'usuario','')) then
    return jsonb_build_object('ok',false,'error','ROL_NO_AUTORIZADO');
  end if;

  -- localizar la fila (match por idProducto cuando viene, si no por codigoBarra) — paridad GAS
  if v_id is not null then
    select * into v_row from mos.productos where id_producto = v_id limit 1;
  elsif v_codmatch is not null then
    select * into v_row from mos.productos where btrim(coalesce(codigo_barra,'')) = v_codmatch limit 1;
  else
    return jsonb_build_object('ok',false,'error','Requiere idProducto o codigoBarra');
  end if;
  if not found then return jsonb_build_object('ok',false,'error','Producto no encontrado'); end if;

  -- validación de precioVenta si viene (no 0 ni vacío) — paridad GAS
  if (p ? 'precioVenta') and nullif(btrim(coalesce(p->>'precioVenta','')),'') is not null then
    v_pv_new := mos._numn(p->>'precioVenta');
    if v_pv_new is null or v_pv_new <= 0 then
      return jsonb_build_object('ok',false,'error','El precio de venta no puede ser 0 ni vacío');
    end if;
  end if;

  -- sincronizar unidad/Unidad_Medida (paridad GAS: si solo uno, copiar; si ambos distintos, prima Unidad_Medida)
  if v_unidad is not null and v_unidadm is null then v_unidadm := v_unidad;
  elsif v_unidadm is not null and v_unidad is null then v_unidad := v_unidadm;
  elsif v_unidad is not null and v_unidadm is not null and v_unidad <> v_unidadm then v_unidad := v_unidadm;
  end if;

  v_pv_old := v_row.precio_venta;

  update mos.productos t set
    sku_base               = case when nullif(btrim(coalesce(p->>'skuBase','')),'') is not null then btrim(p->>'skuBase') else t.sku_base end,
    codigo_barra           = case when nullif(btrim(coalesce(p->>'codigoBarra','')),'') is not null then btrim(p->>'codigoBarra') else t.codigo_barra end,
    descripcion            = case when nullif(btrim(coalesce(p->>'descripcion','')),'') is not null then btrim(p->>'descripcion') else t.descripcion end,
    id_categoria           = case when nullif(btrim(coalesce(p->>'idCategoria','')),'') is not null then btrim(p->>'idCategoria') else t.id_categoria end,
    unidad                 = coalesce(v_unidad, t.unidad),
    unidad_medida          = coalesce(v_unidadm, t.unidad_medida),
    codigo_producto_base   = case when nullif(btrim(coalesce(p->>'codigoProductoBase','')),'') is not null then btrim(p->>'codigoProductoBase') else t.codigo_producto_base end,
    factor_conversion      = case when nullif(btrim(coalesce(p->>'factorConversion','')),'') is not null then mos._numn(p->>'factorConversion') else t.factor_conversion end,
    factor_conversion_base = case when nullif(btrim(coalesce(p->>'factorConversionBase','')),'') is not null then mos._numn(p->>'factorConversionBase') else t.factor_conversion_base end,
    marca                  = case when p ? 'marca'          then nullif(btrim(coalesce(p->>'marca','')),'')      else t.marca end,
    precio_venta           = case when v_pv_new is not null then v_pv_new                                         else t.precio_venta end,
    precio_costo           = case when p ? 'precioCosto'    then mos._numn(p->>'precioCosto')                     else t.precio_costo end,
    cod_tributo            = case when p ? 'Cod_Tributo'    then nullif(btrim(coalesce(p->>'Cod_Tributo','')),'') else t.cod_tributo end,
    igv_porcentaje         = case when p ? 'IGV_Porcentaje' then mos._numn(p->>'IGV_Porcentaje')                  else t.igv_porcentaje end,
    cod_sunat              = case when p ? 'Cod_SUNAT'      then nullif(btrim(coalesce(p->>'Cod_SUNAT','')),'')   else t.cod_sunat end,
    tipo_igv               = case when nullif(btrim(coalesce(p->>'Tipo_IGV','')),'') is not null
                                  and (p->>'Tipo_IGV') in ('1','2','3') then (p->>'Tipo_IGV')::smallint else t.tipo_igv end,
    estado                 = case when p ? 'estado'      then ((p->>'estado')      in ('1','true','t')) else t.estado end,
    es_envasable           = case when p ? 'esEnvasable' then ((p->>'esEnvasable') in ('1','true','t')) else t.es_envasable end,
    -- [597] envase del derivado (VACIABLE: clave presente y vacía → null = "falta elegir") + toggle insumo
    envase_sku             = case when p ? 'envaseSku'   then nullif(btrim(coalesce(p->>'envaseSku','')),'') else t.envase_sku end,
    es_insumo              = case when p ? 'esInsumo'    then ((p->>'esInsumo') in ('1','true','t')) else t.es_insumo end,
    -- [629] precio de ETIQUETA en presentación de granel (regla del saco 25kg)
    precio_fijo            = case when p ? 'precioFijo'  then ((p->>'precioFijo') in ('1','true','t')) else t.precio_fijo end,
    merma_esperada_pct     = case when p ? 'mermaEsperadaPct' then mos._numn(p->>'mermaEsperadaPct') else t.merma_esperada_pct end,
    stock_minimo           = case when p ? 'stockMinimo' then mos._numn(p->>'stockMinimo') else t.stock_minimo end,
    stock_maximo           = case when p ? 'stockMaximo' then mos._numn(p->>'stockMaximo') else t.stock_maximo end,
    zona                   = case when p ? 'zona'        then nullif(btrim(coalesce(p->>'zona','')),'') else t.zona end,
    modo_venta             = case when p ? 'modoVenta'
                                  then (case when upper(coalesce(p->>'modoVenta','')) in ('MARGEN','FIJO','COMPETITIVO','LIBRE')
                                             then upper(p->>'modoVenta') else null end)
                                  else t.modo_venta end,
    margen_pct             = case when p ? 'margenPct'  then mos._numn(p->>'margenPct')  else t.margen_pct end,
    precio_tope            = case when p ? 'precioTope' then mos._numn(p->>'precioTope') else t.precio_tope end,
    updated_at             = now()
  where id_producto = v_row.id_producto;

  -- Normalizar: si tras el update es CANÓNICO (sin base) y factor quedó NULL → setear 1 (modelo normalizado, paridad GAS)
  update mos.productos set factor_conversion = 1
   where id_producto = v_row.id_producto
     and coalesce(btrim(codigo_producto_base),'') = ''
     and factor_conversion is null;

  -- Recalcular tipo_producto (la sombra DEBE quedar consistente; backfill post() rule)
  update mos.productos set tipo_producto =
    case when coalesce(btrim(codigo_producto_base),'') <> '' then 'DERIVADO'::mos.producto_tipo
         when factor_conversion is not null and factor_conversion > 0 and factor_conversion <> 1 then 'PRESENTACION'::mos.producto_tipo
         else 'CANONICO'::mos.producto_tipo end
   where id_producto = v_row.id_producto;

  -- [724] HISTORIAL DE COSTO: esta via pisaba mos.productos.precio_costo (linea `precio_costo = case when
  -- p ? 'precioCosto' ...`) SIN dejar ninguna fila en la tabla de costos. Es la via del modal de catalogo,
  -- por eso source='MOS_CATALOGO' (el MISMO source que ya usa el PRECIO de esa pantalla via publicar_precio).
  begin
    if (p ? 'precioCosto') and mos._numn(p->>'precioCosto') is not null
       and (mos._numn(p->>'precioCosto') is distinct from v_row.precio_costo) then
      insert into mos.historial_precio_costo(id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, app_origen, ts, meta)
      values (v_row.id_producto, coalesce(nullif(btrim(v_row.sku_base),''), v_row.id_producto),
              'COSTO', mos._numn(p->>'precioCosto'), v_row.precio_costo,
              nullif(btrim(coalesce(p->>'usuario','')),''), 'MOS_CATALOGO', 'MOS', now(),
              jsonb_build_object('descripcion', coalesce(v_row.descripcion,'')));
    end if;
  exception when others then null;
  end;

  -- ¿cambió el precio? (tolerancia 0.001 como _valoresIguales de GAS)
  v_cambio_precio := (v_pv_new is not null) and (v_pv_old is null or abs(v_pv_new - v_pv_old) >= 0.001);

  if v_cambio_precio then
    insert into mos.historial_precios (id, sku_base, codigo_barra, descripcion, precio_anterior, precio_nuevo, usuario, motivo, app_origen, fecha)
    select 'HP'||replace(now()::text,' ','_')||substr(md5(random()::text),1,4),
           t.sku_base, t.codigo_barra, t.descripcion, v_pv_old, v_pv_new,
           nullif(btrim(coalesce(p->>'usuario','')),''),
           coalesce(nullif(btrim(coalesce(p->>'motivoPrecio','')),''),'Actualización'), 'MOS', now()
      from mos.productos t where t.id_producto = v_row.id_producto;

    select (coalesce(btrim(codigo_producto_base),'') = ''
            and (factor_conversion is null or factor_conversion = 1)) into v_es_canon
      from mos.productos where id_producto = v_row.id_producto;
    if v_es_canon and not coalesce((p->>'_noPropagar')::boolean, false) then
      v_pres_upd := mos._propagar_precio(v_row.sku_base, v_row.id_producto, v_pv_new,
                                         nullif(btrim(coalesce(p->>'usuario','')),''),
                                         nullif(btrim(coalesce(p->>'motivoPrecio','')),''));
    end if;
  end if;

  return jsonb_build_object('ok',true,'data', jsonb_build_object('presentacionesActualizadas', v_pres_upd));
end;
$function$

;

-- ══════════════════════════════════════════════════════════════════
-- mos.crear_producto
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION mos.crear_producto(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_desc    text := nullif(btrim(coalesce(p->>'descripcion','')), '');
  v_pv      numeric := mos._numn(p->>'precioVenta');
  v_sin     boolean := coalesce((p->>'permitirSinPrecio') in ('1','true','t'), false);  -- [601] solo PN
  v_id      text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_sku     text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_cod     text := btrim(coalesce(p->>'codigoBarra',''));     -- texto SIEMPRE
  v_seq     bigint;
  v_pad     text;
  v_tipoigv text := coalesce(nullif(btrim(coalesce(p->>'Tipo_IGV','')),''),'1');
  v_igvpct  numeric;
  v_codtrib text;
  v_codsun  text;
  v_unidad  text;
  v_unidadm text;
  v_cpb     text := btrim(coalesce(p->>'codigoProductoBase',''));   -- texto SIEMPRE
  v_es_deriv boolean;
  v_es_pres  boolean;
  v_factor  numeric;
  v_fbase   numeric := mos._numn(p->>'factorConversionBase');
  v_tipo    mos.producto_tipo;
  v_modo    text := upper(coalesce(p->>'modoVenta',''));
  v_margen  numeric := mos._numn(p->>'margenPct');
  v_tope    numeric := mos._numn(p->>'precioTope');
  v_dup     record;
  v_inserted int;
  v_sku_in  text;
  v_id_in   text;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- [724] GUARD DE ROL: dar de alta un producto ES fijar su precio (y su costo) por primera vez → ADMIN/MASTER.
  -- El front SIEMPRE manda usuario (api.js crearProducto: usuario:_mosUsuario(p)); la via interna
  -- mos.lanzar_producto_nuevo (aprobacion de PN) reenvia coalesce(p->>'usuario','MOS') y el front de PN manda
  -- S.session.nombre → un PN aprobado SIN sesion (fallback literal 'MOS') queda bloqueado A PROPOSITO.
  if not mos._rol_precio_ok(coalesce(p->>'usuario','')) then return jsonb_build_object('ok',false,'error','ROL_NO_AUTORIZADO'); end if;

  if v_desc is null then return jsonb_build_object('ok',false,'error','La descripción es requerida'); end if;
  -- [601] permitirSinPrecio: el PN puede nacer SIN precio (0 = sello/bloqueo en ME); el alta normal NO.
  if v_pv is null or v_pv <= 0 then
    if not v_sin then
      return jsonb_build_object('ok',false,'error','El precio de venta es requerido y debe ser mayor a 0');
    end if;
    v_pv := 0;
  end if;

  if v_id is not null and exists (select 1 from mos.productos where id_producto = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,
      'data', jsonb_build_object('idProducto', v_id, 'skuBase', coalesce(v_sku, (select sku_base from mos.productos where id_producto=v_id))));
  end if;

  if v_cod <> '' then
    select id_producto, descripcion into v_dup from mos.productos
      where btrim(coalesce(codigo_barra,'')) = v_cod limit 1;
    if found then
      return jsonb_build_object('ok',false,'error',
        'El código de barras '||v_cod||' ya existe en el producto '||v_dup.id_producto||' ('||coalesce(v_dup.descripcion,'sin descripción')||')');
    end if;
  end if;

  v_sku_in := v_sku; v_id_in := v_id;

  if v_id is null or v_sku is null then
    v_seq := nextval('mos.seq_producto');
    v_pad := lpad(v_seq::text, 7, '0');
    v_id  := coalesce(v_id,  'IDPRO'||v_pad);
    v_sku := coalesce(v_sku, 'LEV'||v_pad);
  end if;

  v_tipoigv := case lower(v_tipoigv) when 'gravado' then '1' when 'exonerado' then '2' when 'inafecto' then '3' else v_tipoigv end;
  if v_tipoigv not in ('1','2','3') then v_tipoigv := '1'; end if;
  v_igvpct  := coalesce(mos._numn(p->>'IGV_Porcentaje'), case when v_tipoigv='1' then 18 else 0 end);
  v_codtrib := coalesce(nullif(btrim(coalesce(p->>'Cod_Tributo','')),''),
                        case v_tipoigv when '1' then '1000' when '2' then '9997' when '3' then '9998' else '' end);
  v_codsun  := coalesce(nullif(btrim(coalesce(p->>'Cod_SUNAT','')),''),'10000000');
  v_unidad  := nullif(btrim(coalesce(p->>'unidad','')),'');
  v_unidadm := nullif(btrim(coalesce(p->>'Unidad_Medida','')),'');
  if v_unidad is not null and v_unidadm is not null and v_unidad <> v_unidadm then
    v_unidad := v_unidadm;
  end if;
  v_unidad  := coalesce(v_unidad, v_unidadm, 'NIU');
  v_unidadm := coalesce(v_unidadm, v_unidad, 'NIU');

  v_es_deriv := (v_cpb <> '');
  v_es_pres  := (v_sku_in is not null and v_sku_in <> coalesce(v_id_in, v_id));
  if v_es_pres then
    v_factor := coalesce(mos._numn(p->>'factorConversion'), 1);
  elsif v_es_deriv then
    v_factor := null;
  else
    v_factor := 1;
  end if;
  if v_cpb <> '' then
    v_tipo := 'DERIVADO';
  elsif v_factor is not null and v_factor > 0 and v_factor <> 1 then
    v_tipo := 'PRESENTACION';
  else
    v_tipo := 'CANONICO';
  end if;

  if v_modo not in ('MARGEN','FIJO','COMPETITIVO','LIBRE') then v_modo := null; end if;

  insert into mos.productos (
    id_producto, sku_base, codigo_barra, descripcion, marca, id_categoria, unidad,
    precio_venta, precio_costo, cod_tributo, igv_porcentaje, cod_sunat, tipo_igv, unidad_medida,
    estado, es_envasable, codigo_producto_base, factor_conversion, factor_conversion_base,
    merma_esperada_pct, stock_minimo, stock_maximo, zona, fecha_creacion, creado_por,
    modo_venta, margen_pct, precio_tope, tipo_producto, created_at, updated_at,
    envase_sku, es_insumo, precio_fijo
  ) values (
    v_id, v_sku, nullif(v_cod,''), v_desc,
    nullif(btrim(coalesce(p->>'marca','')),''),
    nullif(btrim(coalesce(p->>'idCategoria','')),''),
    v_unidad,
    v_pv, coalesce(mos._numn(p->>'precioCosto'),0), v_codtrib, v_igvpct, v_codsun, v_tipoigv::smallint, v_unidadm,
    true,
    coalesce((p->>'esEnvasable') in ('1','true','t'), false),
    nullif(v_cpb,''), v_factor, v_fbase,
    mos._numn(p->>'mermaEsperadaPct'),
    coalesce(mos._numn(p->>'stockMinimo'),0), coalesce(mos._numn(p->>'stockMaximo'),0),
    nullif(btrim(coalesce(p->>'zona','')),''),
    now(), nullif(btrim(coalesce(p->>'usuario','')),''),
    v_modo, v_margen, v_tope, v_tipo, now(), now(),
    nullif(btrim(coalesce(p->>'envaseSku','')),''),
    coalesce((p->>'esInsumo') in ('1','true','t'), false),
    coalesce((p->>'precioFijo') in ('1','true','t'), false)   -- [629] etiqueta del saco
  )
  on conflict (id_producto) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    return jsonb_build_object('ok',true,'dedup',true,
      'data', jsonb_build_object('idProducto', v_id, 'skuBase', v_sku));
  end if;

  -- [724] HISTORIAL DE COSTO INICIAL en la tabla de costos (el alta grababa precio_costo sin dejar rastro).
  -- source='ALTA_PRODUCTO'. Solo si nacio CON costo (>0); costo 0 = 'sin costo aun', no es un dato de dinero.
  begin
    if coalesce(mos._numn(p->>'precioCosto'),0) > 0 then
      insert into mos.historial_precio_costo(id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, app_origen, ts, meta)
      values (v_id, v_sku, 'COSTO', mos._numn(p->>'precioCosto'), null,
              nullif(btrim(coalesce(p->>'usuario','')),''), 'ALTA_PRODUCTO', 'MOS', now(),
              jsonb_build_object('descripcion', coalesce(v_desc,'')));
    end if;
  exception when others then null;
  end;

  -- [601] historial de precio inicial SOLO si nació CON precio (0 = SIN PRECIO, sin historial)
  if v_pv > 0 then
    insert into mos.historial_precios (id, sku_base, codigo_barra, descripcion, precio_anterior, precio_nuevo, usuario, motivo, app_origen, fecha)
    values ('HP'||replace(now()::text,' ','_')||substr(md5(random()::text),1,4),
            v_sku, nullif(v_cod,''), v_desc, 0, v_pv, nullif(btrim(coalesce(p->>'usuario','')),''), 'Precio inicial', 'MOS', now());
  end if;

  return jsonb_build_object('ok',true,'dedup',false,
    'data', jsonb_build_object('idProducto', v_id, 'skuBase', v_sku, 'tipo', v_tipo));
end;
$function$

;

-- ════════════════════════════════════════════════════════════════════
-- BUG PREEXISTENTE DETECTADO (NO introducido aquí, NO corregido aquí)
--   mos.publicar_precio(p) sólo agrega 'idProducto' al patch que le pasa a
--   mos.actualizar_producto si `p->>'idProducto'` vino en la entrada. Cuando se la
--   llama SÓLO con skuBase, el patch queda sin idProducto ni codigoBarra y
--   actualizar_producto responde 'Requiere idProducto o codigoBarra'.
--   Medido en la BD contra la definición VIVA (antes de tocar nada):
--     publicar_precio({skuBase:'LEV186',precioNuevo:33.30})    → ok:false
--     publicar_precio({idProducto:'IDPRO0000019',precioNuevo:…}) → ok:true
--   CONSECUENCIA: mos.aplicar_respuesta_jefa SIEMPRE llama con skuBase solo ⇒ hoy
--   devuelve autorizado:true, aplicados:0 y errores[]="Requiere idProducto o
--   codigoBarra". La respuesta de la jefa NO está aplicando precios ni costos.
--   Además, la resolución por skuBase usa `limit 1` sin ORDER BY: puede caer en una
--   PRESENTACIÓN en vez del canónico (comprobado en el ensayo: devolvió la fila
--   "· 20 g" con precioAnterior 1.00 en lugar del canónico a 35.00).
--   FIX SUGERIDO (1 línea, requiere decisión del dueño porque REVIVE un camino de
--   dinero que hoy es inerte):
--     if v_id is null and v_cod is null and v_pid is not null then
--       v_patch := v_patch || jsonb_build_object('idProducto', v_pid); end if;
--   …junto con ordenar el SELECT de resolución para preferir el canónico
--   (factor_conversion=1 and codigo_producto_base='').
-- ════════════════════════════════════════════════════════════════════
