-- ════════════════════════════════════════════════════════════════════════════
-- 417 · Clientes frecuentes: tipo de documento SUNAT explícito + guardado del
--       flujo Extranjero (CE/Pasaporte) + candados de FACTURA
-- ════════════════════════════════════════════════════════════════════════════
-- CONTEXTO (norma SUNAT catálogo 06, verificada 2026-07-11):
--   1=DNI (8 num fijo) · 4=Carné extranjería (hasta 12 ALFANUM) · 6=RUC (11 num,
--   prefijo 10/15/16/17/20) · 7=Pasaporte (hasta 12 ALFANUM).
--   ⚠️ Un CE/Pasaporte PUEDE tener 11 caracteres → inferir tipo por LONGITUD
--   (lo que hacía editar_cliente: 8→DNI, 11→RUC) puede colar un CE numérico de
--   11 dígitos como RUC y habilitar una FACTURA inválida ante SUNAT.
--
-- FIX:
--   1. me.clientes_frecuentes + columna tipo_id ('1'/'4'/'6'/'7'/'0'/'' descono-
--      cido) — el tipo se guarda EXPLÍCITO, nunca más solo inferido. (tipo_doc
--      queda como está: trae basura histórica mixta de comprobantes.)
--   2. Backfill conservador: 8 díg→'1' · 11 díg con prefijo RUC VÁLIDO→'6' ·
--      '66666'→'0' · Jorgenis 008539040→'4' (CE confirmado por el dueño).
--   3. me.guardar_cliente_frecuente(p): upsert directo para el mini-form
--      Extranjero de ME (hoy ese flujo solo llenaba el ticket y el cliente
--      jamás quedaba guardado → por eso Jorgenis tenía 3 docs distintos).
--   4. me.buscar_clientes_frecuentes v2: devuelve tipoId (para que ME sepa al
--      reusar que es CE/Pasaporte → bloquear FACTURA) + búsqueda server-side
--      en vivo desde ME (el cache local del catálogo no ve altas recientes).
--   5. me.editar_cliente v2: acepta tipoId explícito; la inferencia de respaldo
--      valida prefijo RUC real (11 díg sin prefijo válido ya NO se marca 6).
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1) columna tipo_id ────────────────────────────────────────────────────────
alter table me.clientes_frecuentes add column if not exists tipo_id text not null default '';

-- ── 2) backfill conservador (solo lo inequívoco) ─────────────────────────────
update me.clientes_frecuentes set tipo_id = '1'
 where tipo_id = '' and btrim(coalesce(documento,'')) ~ '^\d{8}$';
update me.clientes_frecuentes set tipo_id = '6'
 where tipo_id = '' and btrim(coalesce(documento,'')) ~ '^(10|15|16|17|20)\d{9}$';
update me.clientes_frecuentes set tipo_id = '0'
 where tipo_id = '' and btrim(coalesce(documento,'')) = '66666';
-- Jorgenis (empleado, CE confirmado por el dueño 2026-07-11)
update me.clientes_frecuentes set tipo_id = '4' where btrim(coalesce(documento,'')) = '008539040';

-- ── 3) upsert directo (mini-form Extranjero / DNI manual de ME) ──────────────
create or replace function me.guardar_cliente_frecuente(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app  text := me.jwt_app();
  v_doc  text := btrim(coalesce(p->>'documento',''));
  v_nom  text := btrim(coalesce(p->>'nombre',''));
  v_tid  text := btrim(coalesce(p->>'tipoId',''));
  v_dir  text := btrim(coalesce(p->>'direccion',''));
begin
  if v_app not in ('','MOS','mosExpress') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_doc = '' or v_nom = '' then
    return jsonb_build_object('ok', false, 'error', 'documento y nombre requeridos');
  end if;
  if v_tid not in ('','0','1','4','6','7') then
    return jsonb_build_object('ok', false, 'error', 'tipoId inválido (catálogo 06: 0/1/4/6/7)');
  end if;
  -- El documento es un ID de TEXTO: se respeta tal cual (ceros a la izquierda incluidos).
  insert into me.clientes_frecuentes (documento, nombre, tipo_doc, tipo_id, direccion)
  values (v_doc, v_nom, '', v_tid, v_dir)
  on conflict (documento) do update
    set nombre    = case when btrim(excluded.nombre) <> '' then excluded.nombre else me.clientes_frecuentes.nombre end,
        tipo_id   = case when btrim(excluded.tipo_id) <> '' then excluded.tipo_id else me.clientes_frecuentes.tipo_id end,
        direccion = coalesce(nullif(excluded.direccion,''), me.clientes_frecuentes.direccion);
  return jsonb_build_object('ok', true, 'data', (
    select jsonb_build_object('documento', documento, 'nombre', nombre, 'tipoId', tipo_id, 'direccion', coalesce(direccion,''))
    from me.clientes_frecuentes where documento = v_doc));
end; $fn$;
revoke all on function me.guardar_cliente_frecuente(jsonb) from public, anon;
grant execute on function me.guardar_cliente_frecuente(jsonb) to authenticated, service_role;

-- ── 4) buscador v2: + tipoId (base 284, misma semántica) ─────────────────────
create or replace function me.buscar_clientes_frecuentes(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select jsonb_build_object('ok', true, 'data', coalesce((
    select jsonb_agg(row order by row->>'nombre')
    from (
      select jsonb_build_object(
               'documento', c.documento,
               'nombre',    coalesce(c.nombre,''),
               'tipoComprobante', coalesce(c.tipo_doc,''),
               'tipoId',    coalesce(c.tipo_id,''),
               'direccion', coalesce(c.direccion,'')
             ) as row
      from me.clientes_frecuentes c, (
        select lower(btrim(coalesce(p->>'q',''))) as qn,
               btrim(coalesce(p->>'q','')) as qd
      ) q
      where char_length(q.qn) >= 2
        and ( lower(coalesce(c.nombre,'')) like '%'||q.qn||'%'
              or (q.qd ~ '^\d+$' and c.documento like q.qd||'%') )
      limit 12
    ) s
  ), '[]'::jsonb));
$fn$;
revoke all on function me.buscar_clientes_frecuentes(jsonb) from public;
grant execute on function me.buscar_clientes_frecuentes(jsonb) to authenticated, service_role;

-- ── 5) editar_cliente v2: tipoId explícito + inferencia con prefijo RUC real ─
-- (Verbatim de la versión viva; SOLO cambia el cálculo de v_tdc/tipo y el upsert.)
create or replace function me.editar_cliente(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_app   text := me.jwt_app();
  v_id    text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_doc   text := btrim(coalesce(p->>'clienteDoc',''));
  v_nom   text := btrim(coalesce(p->>'clienteNombre',''));
  v_dir   text := nullif(btrim(coalesce(p->>'clienteDireccion','')),'');
  v_mot   text := coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'');
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_auth  jsonb := coalesce(p->'autorizadoPor','null'::jsonb);
  v_tid   text := btrim(coalesce(p->>'tipoId',''));   -- [417] tipo SUNAT explícito (manda sobre inferencia)
  v_tipo  text;  v_nf text;  v_docA text;  v_nomA text;  v_hist jsonb;
  v_tdc   smallint;
  v_cambios jsonb := '[]'::jsonb;
begin
  if v_app not in ('','MOS','mosExpress') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'idVenta requerido'); end if;
  if v_tid not in ('','0','1','4','6','7') then
    return jsonb_build_object('ok', false, 'error', 'tipoId inválido (catálogo 06: 0/1/4/6/7)');
  end if;

  select tipo_doc, nf_estado, cliente_doc, cliente_nombre, historial_cambios
    into v_tipo, v_nf, v_docA, v_nomA, v_hist
  from me.ventas where id_venta = v_id for update;   -- 264: FOR UPDATE serializa read-then-append
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Venta '||v_id||' no encontrada');
  end if;

  if coalesce(v_tipo,'') <> 'NOTA_DE_VENTA' and coalesce(v_nf,'') = 'EMITIDO' then
    return jsonb_build_object('ok', false,
      'error', 'CPE emitido ('||coalesce(v_tipo,'')||') no se puede editar. Solicite la baja del CPE primero.');
  end if;

  -- [417] tipo_doc_cliente: explícito si vino; la inferencia de respaldo exige
  -- prefijo RUC REAL para marcar 6 (un CE/Pasaporte numérico de 11 díg ya no
  -- se disfraza de RUC → no habilita FACTURA). Catálogo 06: 1 DNI · 4 CE · 6 RUC · 7 Pasaporte.
  v_tdc := case
             when v_tid <> '' then case v_tid when '1' then 1 when '4' then 4 when '6' then 6 when '7' then 7 else 0 end
             when v_doc ~ '^\d{8}$' then 1
             when v_doc ~ '^(10|15|16|17|20)\d{9}$' then 6
             else 0
           end;

  if coalesce(v_docA,'') <> v_doc then
    v_cambios := v_cambios || jsonb_build_array(jsonb_build_object('campo','Cliente_Doc','antes',coalesce(v_docA,''),'despues',v_doc));
  end if;
  if coalesce(v_nomA,'') <> v_nom then
    v_cambios := v_cambios || jsonb_build_array(jsonb_build_object('campo','Cliente_Nombre','antes',coalesce(v_nomA,''),'despues',v_nom));
  end if;

  update me.ventas
    set cliente_doc = v_doc,
        cliente_nombre = v_nom,
        tipo_doc_cliente = v_tdc,
        historial_cambios = case when jsonb_array_length(v_cambios) > 0
          then me._venta_hist_append(v_hist, jsonb_build_object(
            'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
            'source', 'ME_EDITAR_CLIENTE', 'accion', 'editar_cliente',
            'cambios', v_cambios, 'autorizadoPor', v_auth, 'motivo', v_mot))
          else historial_cambios end,
        updated_at = now()
    where id_venta = v_id;

  -- Back-fill del directorio de clientes frecuentes (paridad con verificarYAgregaCliente del GAS).
  -- No pisa nombre/direccion existentes con vacío (solo rellena si estaban vacíos).
  if v_doc <> '' and v_nom <> '' then
    insert into me.clientes_frecuentes (documento, nombre, tipo_doc, tipo_id, direccion)
    values (v_doc, v_nom, v_tdc::text, case when v_tid <> '' then v_tid else case v_tdc when 1 then '1' when 6 then '6' else '' end end, v_dir)
    on conflict (documento) do update
      set nombre = case when btrim(coalesce(me.clientes_frecuentes.nombre,''))='' then excluded.nombre else me.clientes_frecuentes.nombre end,
          tipo_id = case when btrim(excluded.tipo_id) <> '' then excluded.tipo_id else me.clientes_frecuentes.tipo_id end,
          direccion = coalesce(nullif(excluded.direccion,''), me.clientes_frecuentes.direccion);
  end if;

  return jsonb_build_object('ok', true, 'mensaje', 'Cliente actualizado',
    'idVenta', v_id, 'cambios', jsonb_array_length(v_cambios));
end;
$function$;

revoke all on function me.editar_cliente(jsonb) from public;
grant execute on function me.editar_cliente(jsonb) to authenticated, service_role;

notify pgrst, 'reload schema';
