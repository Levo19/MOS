-- 1054 · Control de cajeros (reporte semanal para el área administrativa) · SOLO SQL
-- Pedido de Luis 27-nov-2026: ambas zonas, de lunes a hoy (hora Lima); arqueo, ventas por método,
-- anulaciones (quién/cuándo/motivo), extras "no permitidos", Yapes leídos por el captor y qué tickets
-- verificó cada uno, tickets virtuales sin verificar, clientes por caja, y una marca de revisión
-- (OK / OBSERVADO + nota) por caja, extra, venta, Yape o anulado.
--
-- Objetos:
--   mos.control_caja_revision      marca vigente por (tipo, ref). RLS on, sin grants (solo vía RPC).
--   mos.control_caja_revision_log  bitácora append-only de cada marca y de cada borrado (auditoría).
--   mos._control_caja_nivel(text)  nivel (ALTA/MEDIA/BAJA) de cada código de alerta o flag.
--   mos._control_caja_ts(text)     lee el ts de un historial: ISO con zona; ISO sin zona = hora Lima;
--                                  epoch en ms (12-13 dígitos); otro formato → null (flag TS_ILEGIBLE).
--   mos.reporte_cajas_semana(p)    lectura. p {usuario,desde,hasta,zona,ventas}. Default: lunes de esta
--                                  semana → hoy (Lima). Rango máximo 31 días (si no, RANGO_INVALIDO).
--   mos.control_caja_marcar(p)     escritura. p {usuario,tipo,ref,estado,nota}; estado JSON null explícito
--                                  = borrar marca; clave ausente o '' → ESTADO_INVALIDO.
-- Guard: me.jwt_app() = 'MOS'. Sin anon. LECTURA y ESCRITURA exigen p.usuario con rol ADMIN/MASTER vía
-- mos._control_caja_rol_ok (= mos._rol_precio_ok de 1051 SIN la puerta acceso_mos: rol_nivel >= 2 o
-- lista COSTO_PRECIO_USUARIOS_EXTRA); si no → ROL_NO_AUTORIZADO. Es información de dinero de los cajeros.
-- USUARIO DECLARADO vs JWT: el token de MOS (Edge mint-mos) solo trae app='MOS' y sub = id del EQUIPO
-- (mos.dispositivos.id_dispositivo); no trae la persona. No se puede verificar criptográficamente quién
-- es p.usuario. Mitigación: control_caja_marcar guarda en la bitácora el sub real del JWT, la sesión que
-- ese equipo tiene registrada (mos.dispositivos.ultima_sesion) y si coincide con p.usuario
-- (coincide_sesion). No se bloquea por discrepancia (ultima_sesion guarda solo el nombre de pila y
-- puede estar desfasada); queda para auditoría.
-- TIEMPO: no se fija statement_timeout en la función: bajo el rol authenticated de PostgREST manda el
-- del rol (8 s) y un SET en la función no lo amplía. Ensayo: semana completa TODAS en ~1-2 s.
-- OJO PostgREST (pg_safeupdate): todo UPDATE/DELETE lleva WHERE (ninguno es sobre todo el set).
--
-- ALCANCE DEL RANGO: cajas cuya apertura O cierre (hora Lima) cae en el rango, más las que siguen
--   ABIERTAS si el rango llega a hoy. Además, movimientos TARDÍOS sobre cajas de antes del rango:
--   extras con ts en el rango y anulaciones con ts (historial) en el rango → salen en extras[] /
--   anulados[] con flag TARDIO_OTRA_SEMANA y tardio:true, pero NO suman en cajas[] ni en los totales del
--   resumen (su caja pertenece a otra semana); se cuentan aparte en resumen.tardios_extras_n /
--   tardios_anulados_n.
--
-- ARQUEO (idéntico a me.cerrar_caja / me.cerrar_caja_forzado, que es lo que se guarda en monto_final):
--   esperado_efectivo = monto_inicial
--                     + Σ ventas de la caja con forma_pago EFECTIVO (total) o MIXTO (parte 'EFE:x')
--                       EXCEPTO las ventas cobradas después por un extra 'Abono deuda' ("ticket <id>"),
--                       porque ese efectivo entró en la caja del abono (si no, se cuenta 2 veces)
--                     + INGRESO − EGRESO (extras en efectivo). Virtuales, CREDITO, PLANILLA, POR_COBRAR
--                       y ANULADO% no suman. Un POR_COBRAR cobrado en ME cambia su forma_pago a
--                       EFECTIVO/VIRTUAL en la misma venta, así que entra solo.
--   ⚠ me.datos_turno (ticket Z) NO excluye los abonos: para una venta a crédito cobrada otro día
--     duplica ese efectivo (ej. caja de Javier 24-nov: datos_turno 31.50, cerrar_caja/monto_final 5.00).
--   diferencia = monto_final − esperado (solo cajas cerradas). ≠ 0 ⇒ se declaró otro monto al cerrar o
--   algo cambió DESPUÉS del cierre (extra agregado/editado, anulación, cobro de crédito).
--   El arqueo es ESPEJO ESTRICTO de cerrar_caja: upper(forma_pago) SIN btrim = 'EFECTIVO' / like 'MIXTO%'
--   con regex 'EFE:([0-9.]+)' (sensible a mayúsculas, sin espacios); extras por tipo EXACTO
--   ('INGRESO' / 'EGRESO', sin upper ni coalesce). Lo MOSTRADO (metodo, efe, vir, extras_ingreso…) es
--   tolerante (btrim, upper, 'EFE: x', tipo vacío → EGRESO) y puede diferir del arqueo solo con datos
--   mal formados; esas diferencias no tocan esperado_efectivo.
--
-- MÉTODO de cada venta (por forma_pago actual): ANULADO% → ANULADO · '' / EFECTIVO → EFECTIVO ·
--   VIRTUAL · CREDITO · PLANILLA → CREDITO (consumo del personal a planilla; forma_pago lo dice) ·
--   POR_COBRAR · MIXTO% → MIXTO (efe/vir del texto 'MIXTO (VIR:x/EFE:y)') · otro → VIRTUAL (como datos_turno).
--   resumen.efectivo/virtual/credito/por_cobrar/mixto_efe/mixto_vir suman ventas_total (mezcla de venta);
--   el ARQUEO es otra cosa (ver arriba).
-- ANULADOS: forma_pago = 'ANULADO'. ANULADO_CONVERSION (NV convertida a CPE, 1046) NO es anulación:
--   no entra en anulados[] ni en anulados_n (sí aparece en ventas[] con metodo ANULADO).
--   Quién/cuándo/motivo: última entrada de ventas.historial_cambios cuyo cambio lleva despues ANULADO%
--   (la escribe me.anular_venta: usuario, ts, motivo, autorizadoPor, source). Sin historial = anulación
--   sin rastro (p. ej. me.cerrar_caja anula los POR_COBRAR sin historial) → sin_historial:true.
-- VERIFICACIÓN de virtuales = mos._venta_cubierta: Yape MATCHEADO con id_venta (1:1) o enlace en
--   mos.yape_ventas (Yape global de 2-3 tickets). Monto a verificar = me._monto_virtual (parte VIR).
--   CAPTOR por zona y día = hay equipo activo con captura_yapes en mos.yape_dispositivos para la zona
--   Y llegó al menos 1 Yape de esa zona ese día (la ZONA-01 tiene equipo activo pero no lee Yapes desde
--   el 19-nov). Sin captor ⇒ estado SIN_CAPTOR y verificado = null (no se puede exigir).
--   Venta a crédito cobrada luego con un 'Abono deuda' (cobrado_en = caja del abono) y sin Yape propio:
--   NO se exige verificación (el dinero entró por el extra del abono) → estado_virtual 'COBRO_ABONO',
--   verificado null, fuera de tickets_virtuales y de los conteos de virtuales.
--   p.ventas = 'OBSERVABLES' (opcional) recorta ventas[] a lo no-EFECTIVO, anulado, crédito sin cliente,
--   cobrado por abono o con revisión (la semana completa pesa ~800 KB; el resumen y las cajas no cambian).
--   candidatos (solo lectura, NO se escribe ningún match): Yapes NUEVO/AMBIGUO de la misma zona,
--   ±20 min, con monto = parte virtual (a 1 decimal, como yape_matchear) o = parte virtual + la de otro
--   ticket virtual sin verificar de la misma caja a ±20 min (combo_con = ese id_venta), o 2 Yapes
--   sin match a ±20 min que juntos suman la parte virtual (combo_yape = id del otro Yape; solo si la
--   parte virtual es >= S/ 20: con montos chicos, S/ 1 + S/ 2.80, salen combinaciones casuales).
--
-- ALERTAS por caja (codigo · nivel):
--   ABIERTA_MAS_14H (ALTA)       caja abierta hace más de 14 h.
--   ABIERTA_DIA_ANTERIOR (ALTA)  caja ABIERTA que se abrió antes de hoy (Lima).
--   DIFERENCIA (ALTA si |dif| >= 5, si no MEDIA)  cerrada con monto_final ≠ esperado.
--   ESPERADO_NEGATIVO (ALTA)     arqueo esperado < 0 (egresos mayores que el efectivo).
--   EXTRA_CIERRE (ALTA)          extra cuyo concepto u obs menciona "cierre": doble resta del efectivo.
--   EXTRAS_OBSERVADOS (MEDIA)    n extras con flag MEDIA (ver flags de extras).
--   VIRTUAL_SIN_YAPE (MEDIA)     ventas virtuales/mixtas sin Yape que las verifique, en zona con captor.
--   YAPE_SIN_VENTA (MEDIA)       Yapes NUEVO/AMBIGUO de la zona, > 30 min sin venta. Cada Yape se
--                                atribuye a UNA sola caja: la de su zona abierta en ese momento con la
--                                apertura más reciente (los Yapes no traen estación, no se puede afinar
--                                más). Un Yape sin caja abierta no se atribuye (sí cuenta en el resumen).
--   ANULACIONES (MEDIA)          relativo: >= 3 anulaciones Y (más del doble del promedio por caja de la
--                                misma zona en el rango, o más del 5 % de los tickets de la caja);
--                                o alguna anulación > S/ 50.
--   CREDITO_SIN_CLIENTE (MEDIA)  venta CREDITO/PLANILLA/POR_COBRAR sin cliente identificado.
--   POST_CIERRE (MEDIA)          extras registrados o ventas anuladas después del cierre de la caja.
--   CERRADA_AUTO (BAJA)          la cerró el sistema/forzado (el cajero no cerró).
--   SIN_CAPTOR (BAJA)            hubo ventas virtuales pero la zona no tenía captor Yape ese día.
--   EXTRA_DESDE_MOS (BAJA)       extras creados desde MOS (admin), no por el cajero.
-- FLAGS de extras (codigo · nivel):
--   CIERRE (ALTA) · EGRESO_SIN_CONCEPTO (MEDIA: EGRESO en efectivo sin concepto o con < 4 letras) ·
--   EDITADO (MEDIA: historial_cambios con acción distinta de CREAR/ALTA, me._movext_editado) ·
--   EGRESO_MAYOR_100 (MEDIA: EGRESO en efectivo > S/ 100) · POST_CIERRE (MEDIA: ts > fecha_cierre) ·
--   DESDE_MOS (BAJA: creado en MOS, historial con CREAR) · OTRO_USUARIO (BAJA: registrado_por ≠ cajero) ·
--   CONCEPTO_LIBRE (BAJA: fuera de los conceptos rápidos de ME) · CONSUMO_PERSONAL (BAJA: obs con la
--   PALABRA completa desayuno/almuerzo/cena/adelanto/pasaje/menú; "escena" o "cenar" no cuentan) ·
--   TARDIO_OTRA_SEMANA (MEDIA: extra de una caja de antes del rango registrado dentro del rango).
--   "Extra no permitido" = extra con algún flag ALTA o MEDIA (campo nivel del extra).
--   No hay catálogo de conceptos en la BD: los conceptos rápidos viven en el front de ME
--   (MosExpress/index.html: EGRESO 'Retiro jefe','Pago proveedor','Gasto operativo','Fondo cambio';
--   INGRESO 'Abono deuda','Adelanto cliente','Retorno efectivo','Otro ingreso').
-- FLAGS de ventas: CREDITO_SIN_CLIENTE (MEDIA) · VIRTUAL_SIN_YAPE (MEDIA) · ANULADO_MAYOR_50 (MEDIA) ·
--   ANULADO_POST_CIERRE (MEDIA) · COBRADO_EN_OTRA_CAJA (BAJA) · TS_ILEGIBLE (BAJA: el ts de la
--   anulación en el historial no es ISO ni epoch ms) · TARDIO_OTRA_SEMANA (MEDIA, en anulados[]).
-- FLAGS de Yapes: SIN_VENTA_30M (MEDIA) · DIFERENCIA_TICKETS (MEDIA: matcheado y monto ≠ suma de tickets).
-- resumen.alertas_n = alertas de caja con nivel ALTA o MEDIA (alertas_alta_n = solo ALTA).

set lock_timeout = '5s';

create table if not exists mos.control_caja_revision (
  id      bigserial primary key,
  tipo    text not null check (tipo in ('CAJA','EXTRA','VENTA','YAPE','ANULADO')),
  ref     text not null,
  estado  text not null check (estado in ('OK','OBSERVADO')),
  nota    text,
  usuario text,
  ts      timestamptz not null default now(),
  unique (tipo, ref)
);
alter table mos.control_caja_revision enable row level security;
revoke all on mos.control_caja_revision from public, anon, authenticated;
revoke all on sequence mos.control_caja_revision_id_seq from public, anon, authenticated;

create table if not exists mos.control_caja_revision_log (
  id       bigserial primary key,
  tipo     text not null,
  ref      text not null,
  accion   text not null check (accion in ('MARCAR','BORRAR')),
  estado   text,
  nota     text,
  usuario  text,
  antes    jsonb,
  jwt_sub  text,
  sesion_equipo text,
  coincide_sesion boolean,
  ts       timestamptz not null default now()
);
create index if not exists ix_ccr_log_ref on mos.control_caja_revision_log (tipo, ref, ts desc);
alter table mos.control_caja_revision_log enable row level security;
revoke all on mos.control_caja_revision_log from public, anon, authenticated;
revoke all on sequence mos.control_caja_revision_log_id_seq from public, anon, authenticated;

create or replace function mos._control_caja_nivel(p_codigo text)
 returns text
 language sql
 immutable
 set search_path to ''
as $function$
  select case p_codigo
    when 'ABIERTA_MAS_14H'      then 'ALTA'
    when 'ABIERTA_DIA_ANTERIOR' then 'ALTA'
    when 'ESPERADO_NEGATIVO'    then 'ALTA'
    when 'EXTRA_CIERRE'         then 'ALTA'
    when 'CIERRE'               then 'ALTA'
    when 'EXTRAS_OBSERVADOS'    then 'MEDIA'
    when 'VIRTUAL_SIN_YAPE'     then 'MEDIA'
    when 'YAPE_SIN_VENTA'       then 'MEDIA'
    when 'ANULACIONES'          then 'MEDIA'
    when 'CREDITO_SIN_CLIENTE'  then 'MEDIA'
    when 'POST_CIERRE'          then 'MEDIA'
    when 'EGRESO_SIN_CONCEPTO'  then 'MEDIA'
    when 'EDITADO'              then 'MEDIA'
    when 'EGRESO_MAYOR_100'     then 'MEDIA'
    when 'ANULADO_MAYOR_50'     then 'MEDIA'
    when 'ANULADO_POST_CIERRE'  then 'MEDIA'
    when 'SIN_VENTA_30M'        then 'MEDIA'
    when 'DIFERENCIA_TICKETS'   then 'MEDIA'
    when 'TARDIO_OTRA_SEMANA'   then 'MEDIA'
    else 'BAJA'
  end;
$function$;
revoke all on function mos._control_caja_nivel(text) from public, anon, authenticated;

create or replace function mos._control_caja_ts(p_txt text)
 returns timestamptz
 language plpgsql
 stable
 set search_path to ''
as $function$
declare
  s text := btrim(coalesce(p_txt, ''));
begin
  if s = '' then
    return null;
  end if;
  if s ~ '^[0-9]{12,13}$' then
    return to_timestamp(s::numeric / 1000);
  end if;
  if s ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}' then
    if s ~ '(Z|[+-][0-9]{2}(:?[0-9]{2})?)$' then
      return s::timestamptz;
    end if;
    return (s::timestamp) at time zone 'America/Lima';
  end if;
  return null;
exception when others then
  return null;
end; $function$;
revoke all on function mos._control_caja_ts(text) from public, anon, authenticated;

-- Rol para el control de cajas: como mos._rol_precio_ok pero SIN la puerta acceso_mos (esa deja pasar a
-- un ALMACENERO con acceso a MOS, p. ej. "Jesus", y este reporte expone el dinero de los cajeros).
-- Solo rol_nivel >= 2 (ADMIN/MASTER) por nombre, nombre+apellido o id_personal, o la lista
-- COSTO_PRECIO_USUARIOS_EXTRA (hoy vacía).
create or replace function mos._control_caja_rol_ok(p_usuario text)
 returns boolean
 language sql
 stable
 security definer
 set search_path to ''
as $function$
  select case when btrim(coalesce(p_usuario, '')) = '' then false else (
    exists (
      select 1 from mos.personal pe
       where coalesce(pe.estado, true)
         and mos.rol_nivel(pe.rol) >= 2
         and (
              upper(regexp_replace(btrim(coalesce(pe.nombre, '')), '[[:space:]]+', ' ', 'g'))
                = upper(regexp_replace(btrim(p_usuario), '[[:space:]]+', ' ', 'g'))
           or upper(regexp_replace(btrim(coalesce(pe.nombre, '') || ' ' || coalesce(pe.apellido, '')), '[[:space:]]+', ' ', 'g'))
                = upper(regexp_replace(btrim(p_usuario), '[[:space:]]+', ' ', 'g'))
           or upper(btrim(coalesce(pe.id_personal, ''))) = upper(btrim(p_usuario))
         )
    )
    or exists (
      select 1 from mos.config c
       cross join lateral unnest(string_to_array(coalesce(c.valor, ''), ',')) w(x)
       where c.clave = 'COSTO_PRECIO_USUARIOS_EXTRA'
         and btrim(w.x) <> ''
         and upper(regexp_replace(btrim(w.x), '[[:space:]]+', ' ', 'g'))
             = upper(regexp_replace(btrim(p_usuario), '[[:space:]]+', ' ', 'g'))
    )
  ) end;
$function$;
revoke all on function mos._control_caja_rol_ok(text) from public, anon, authenticated;

create or replace function mos.reporte_cajas_semana(p jsonb default '{}'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_usr   text := btrim(coalesce(p->>'usuario', ''));
  v_tz    constant text := 'America/Lima';
  v_now   timestamptz := now();
  v_hoy   date := (now() at time zone 'America/Lima')::date;
  v_desde date;
  v_hasta date;
  v_zona  text := upper(coalesce(nullif(btrim(p->>'zona'), ''), 'TODAS'));
  v_lite  boolean := coalesce(p->>'ventas', '') = 'OBSERVABLES';
  v_res jsonb; v_cajas jsonb; v_extras jsonb; v_ventas jsonb; v_anul jsonb; v_yapes jsonb;
  v_cli jsonb; v_tv jsonb;
begin
  if coalesce(me.jwt_app(), '') <> 'MOS' then
    return jsonb_build_object('ok', false, 'error', 'NO_AUTORIZADO');
  end if;
  if v_usr = '' or not mos._control_caja_rol_ok(v_usr) then
    return jsonb_build_object('ok', false, 'error', 'ROL_NO_AUTORIZADO');
  end if;
  if v_zona not in ('TODAS', 'ZONA-01', 'ZONA-02') then
    return jsonb_build_object('ok', false, 'error', 'ZONA_INVALIDA');
  end if;
  begin
    v_desde := coalesce(nullif(btrim(p->>'desde'), '')::date, date_trunc('week', v_hoy::timestamp)::date);
    v_hasta := coalesce(nullif(btrim(p->>'hasta'), '')::date, v_hoy);
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'FECHA_INVALIDA');
  end;
  if v_hasta < v_desde or v_hasta - v_desde > 31 then
    return jsonb_build_object('ok', false, 'error', 'RANGO_INVALIDO');
  end if;

  drop table if exists _rcs_k;
  drop table if exists _rcs_v;
  drop table if exists _rcs_e;
  drop table if exists _rcs_y;
  drop table if exists _rcs_cand;
  drop table if exists _rcs_cap;

  -- cajas: apertura o cierre en el rango (Lima) + las ABIERTAS aún (si el rango llega a hoy)
  create temp table _rcs_k on commit drop as
  select k.id_caja, coalesce(k.zona_id, '') zona_id, coalesce(k.vendedor, '') vendedor,
         coalesce(k.estacion, '') estacion, coalesce(k.estado, '') estado,
         k.fecha_apertura, k.fecha_cierre,
         round(coalesce(k.monto_inicial, 0), 2) monto_inicial, k.monto_final,
         (k.fecha_apertura at time zone v_tz)::date dia
    from me.cajas k
   where k.zona_id like 'ZONA-%'
     and (v_zona = 'TODAS' or k.zona_id = v_zona)
     and ( (k.fecha_apertura at time zone v_tz)::date between v_desde and v_hasta
        or (k.fecha_cierre at time zone v_tz)::date between v_desde and v_hasta
        or (k.estado = 'ABIERTA' and v_hasta >= v_hoy) );
  create unique index on _rcs_k (id_caja);

  -- zona/día con captor Yape activo (equipo activo que captura + al menos 1 Yape ese día)
  create temp table _rcs_cap on commit drop as
  select distinct y.zona, y.dia
    from mos.yapes_entrantes y
   where y.dia between (select coalesce(min(dia), v_desde) from _rcs_k) and v_hasta
     and exists (select 1 from mos.yape_dispositivos d
                  where d.activo and d.captura_yapes and d.zona = y.zona);

  -- ventas de esas cajas
  create temp table _rcs_v on commit drop as
  with b as (
    select v.id_venta, v.id_caja, coalesce(nullif(v.zona_id, ''), k.zona_id) zona_id, v.fecha,
           coalesce(v.vendedor, '') vendedor, coalesce(v.correlativo, '') correlativo,
           coalesce(nullif(v.tipo_doc, ''), 'NOTA_DE_VENTA') tipo_doc,
           coalesce(v.cliente_doc, '') cliente_doc, coalesce(v.cliente_nombre, '') cliente_nombre,
           round(coalesce(v.total, 0), 2) total, coalesce(v.forma_pago, '') forma_pago,
           upper(btrim(coalesce(v.forma_pago, ''))) fp,
           v.nf_estado, coalesce(v.obs, '') obs, v.historial_cambios,
           k.fecha_cierre caja_cierre,
           (v.fecha at time zone v_tz)::date dia,
           false tardio
      from me.ventas v
      join _rcs_k k on k.id_caja = v.id_caja
    union all
    -- anulaciones TARDÍAS: venta de una caja de antes del rango, anulada dentro del rango
    -- (prefiltro por updated_at, que me.anular_venta pone en now(); el filtro fino es el ts del historial)
    select v.id_venta, v.id_caja, coalesce(nullif(v.zona_id, ''), k2.zona_id), v.fecha,
           coalesce(v.vendedor, ''), coalesce(v.correlativo, ''),
           coalesce(nullif(v.tipo_doc, ''), 'NOTA_DE_VENTA'),
           coalesce(v.cliente_doc, ''), coalesce(v.cliente_nombre, ''),
           round(coalesce(v.total, 0), 2), coalesce(v.forma_pago, ''),
           upper(btrim(coalesce(v.forma_pago, ''))),
           v.nf_estado, coalesce(v.obs, ''), v.historial_cambios,
           k2.fecha_cierre, (v.fecha at time zone v_tz)::date,
           true
      from me.ventas v
      join me.cajas k2 on k2.id_caja = v.id_caja
     where v.forma_pago = 'ANULADO'
       and (v.updated_at at time zone v_tz)::date between v_desde and v_hasta
       and k2.zona_id like 'ZONA-%'
       and (v_zona = 'TODAS' or k2.zona_id = v_zona)
       and not exists (select 1 from _rcs_k kk where kk.id_caja = v.id_caja)
  ), m as (
    select b.*,
           case when b.fp like 'ANULADO%' then 'ANULADO'
                when b.fp in ('', 'EFECTIVO') then 'EFECTIVO'
                when b.fp = 'VIRTUAL' then 'VIRTUAL'
                when b.fp in ('CREDITO', 'PLANILLA') then 'CREDITO'
                when b.fp = 'POR_COBRAR' then 'POR_COBRAR'
                when b.fp like 'MIXTO%' then 'MIXTO'
                else 'VIRTUAL' end metodo,
           me._monto_virtual(b.forma_pago, b.total) vir_raw,
           (btrim(b.cliente_doc) !~ '^[0]*$' and btrim(b.cliente_doc) not in ('66666', '99999999')
             and upper(btrim(b.cliente_nombre)) not in ('', 'VARIOS', 'CLIENTES VARIOS', 'CLIENTE VARIOS')) cli_ok
      from b
  )
  select m.*,
         round(case when m.metodo = 'EFECTIVO' then m.total
                    when m.metodo = 'MIXTO' then
                      coalesce(((regexp_match(m.forma_pago, 'EFE:[[:space:]]*([0-9]+(?:\.[0-9]+)?)', 'i'))[1])::numeric,
                               m.total - coalesce(m.vir_raw, 0))
                    else 0 end, 2) efe,
         round(case when m.metodo = 'VIRTUAL' then m.total
                    when m.metodo = 'MIXTO' then coalesce(m.vir_raw, 0)
                    else 0 end, 2) vir,
         round(case when upper(m.forma_pago) = 'EFECTIVO' then m.total
                    when upper(m.forma_pago) like 'MIXTO%'
                      then coalesce((regexp_match(m.forma_pago, 'EFE:([0-9.]+)'))[1]::numeric, 0)
                    else 0 end, 2) efe_arqueo,
         ab.id_caja abono_caja,
         case when m.metodo = 'ANULADO' then null
              when ab.id_caja is not null and y1.id is null and yg.id_yape is null then null
              else m.vir_raw end vir_ver,
         coalesce(y1.id, yg.id_yape) id_yape,
         exists (select 1 from _rcs_cap c where c.zona = m.zona_id and c.dia = m.dia) captor,
         an.e anul_hist,
         mos._control_caja_ts(an.e->>'ts') anul_ts,
         (an.e is not null and btrim(coalesce(an.e->>'ts', '')) <> ''
           and mos._control_caja_ts(an.e->>'ts') is null) anul_ts_ilegible
    from m
    left join (
      select distinct on (a.id_venta) a.id_venta, a.id_caja
        from (select nullif(btrim(substring(x.obs from 'ticket ([^ ]+)')), '') id_venta, x.id_caja, x.ts
                from me.movimientos_extra x
               where x.concepto = 'Abono deuda' and coalesce(x.obs, '') <> '') a
       where a.id_venta is not null
       order by a.id_venta, a.ts) ab on ab.id_venta = m.id_venta
    left join lateral (
      select y.id from mos.yapes_entrantes y
       where y.id_venta = m.id_venta and y.estado = 'MATCHEADO' limit 1) y1 on true
    left join lateral (
      select yv.id_yape from mos.yape_ventas yv where yv.id_venta = m.id_venta) yg on true
    left join lateral (
      select h.e from jsonb_array_elements(case when jsonb_typeof(m.historial_cambios) = 'array'
                                                then m.historial_cambios else '[]'::jsonb end)
                      with ordinality h(e, o)
       where m.metodo = 'ANULADO'
         and exists (select 1 from jsonb_array_elements(case when jsonb_typeof(h.e->'cambios') = 'array'
                                                             then h.e->'cambios' else '[]'::jsonb end) c
                      where upper(coalesce(c->>'despues', '')) like 'ANULADO%')
       order by h.o desc limit 1) an on true
   where not m.tardio
      or (mos._control_caja_ts(an.e->>'ts') at time zone v_tz)::date between v_desde and v_hasta;
  create index on _rcs_v (id_caja);

  -- candidatos de Yape para virtuales sin verificar (solo lectura)
  create temp table _rcs_cand on commit drop as
  with sv as (
    select v.id_venta, v.id_caja, v.zona_id, v.fecha, v.vir_ver
      from _rcs_v v
     where v.metodo in ('VIRTUAL', 'MIXTO') and v.vir_ver is not null and v.vir_ver > 0 and v.id_yape is null
  )
  select s.id_venta, y.id, y.monto, coalesce(y.pagador, '') pagador, y.ts_notificacion ts, null::text combo_con,
         null::bigint combo_yape
    from sv s
    join mos.yapes_entrantes y
      on y.estado in ('NUEVO', 'AMBIGUO') and y.monto is not null and y.zona = s.zona_id
     and y.ts_notificacion between s.fecha - interval '20 minutes' and s.fecha + interval '20 minutes'
     and round(y.monto, 1) = round(s.vir_ver, 1)
  union all
  select s.id_venta, y.id, y.monto, coalesce(y.pagador, ''), y.ts_notificacion, s2.id_venta, null::bigint
    from sv s
    join sv s2 on s2.id_caja = s.id_caja and s2.id_venta <> s.id_venta
              and s2.fecha between s.fecha - interval '20 minutes' and s.fecha + interval '20 minutes'
    join mos.yapes_entrantes y
      on y.estado in ('NUEVO', 'AMBIGUO') and y.monto is not null and y.zona = s.zona_id
     and y.ts_notificacion between least(s.fecha, s2.fecha) - interval '20 minutes'
                               and greatest(s.fecha, s2.fecha) + interval '20 minutes'
     and round(y.monto, 1) = round(s.vir_ver + s2.vir_ver, 1)
     and round(y.monto, 1) <> round(s.vir_ver, 1)
  union all
  select s.id_venta, y.id, y.monto, coalesce(y.pagador, ''), y.ts_notificacion, null::text, y2.id
    from sv s
    join mos.yapes_entrantes y
      on y.estado in ('NUEVO', 'AMBIGUO') and y.monto is not null and y.zona = s.zona_id
     and y.ts_notificacion between s.fecha - interval '20 minutes' and s.fecha + interval '20 minutes'
     and y.monto < s.vir_ver and s.vir_ver >= 20
    join mos.yapes_entrantes y2
      on y2.id <> y.id and y2.estado in ('NUEVO', 'AMBIGUO') and y2.monto is not null and y2.zona = s.zona_id
     and y2.ts_notificacion between s.fecha - interval '20 minutes' and s.fecha + interval '20 minutes'
     and round(y.monto + y2.monto, 1) = round(s.vir_ver, 1);

  -- extras de esas cajas con flags
  create temp table _rcs_e on commit drop as
  with b as (
    select x.id_extra, x.id_caja, coalesce(nullif(x.zona_id, ''), k.zona_id) zona_id,
           coalesce(x.ts, x.created_at) ts, upper(coalesce(nullif(x.tipo, ''), 'EGRESO')) tipo,
           round(coalesce(x.monto, 0), 2) monto, coalesce(x.concepto, '') concepto, coalesce(x.obs, '') obs,
           coalesce(x.registrado_por, '') registrado_por,
           me._movext_editado(x.historial_cambios) editado,
           exists (select 1 from jsonb_array_elements(me._movext_hist(x.historial_cambios)) h
                    where upper(coalesce(h->>'accion', '')) = 'CREAR') desde_mos,
           k.vendedor cajero, k.fecha_cierre, x.tipo tipo_raw, false tardio
      from me.movimientos_extra x
      join _rcs_k k on k.id_caja = x.id_caja
    union all
    -- extras TARDÍOS: caja de antes del rango, extra registrado dentro del rango
    select x.id_extra, x.id_caja, coalesce(nullif(x.zona_id, ''), k2.zona_id),
           coalesce(x.ts, x.created_at), upper(coalesce(nullif(x.tipo, ''), 'EGRESO')),
           round(coalesce(x.monto, 0), 2), coalesce(x.concepto, ''), coalesce(x.obs, ''),
           coalesce(x.registrado_por, ''),
           me._movext_editado(x.historial_cambios),
           exists (select 1 from jsonb_array_elements(me._movext_hist(x.historial_cambios)) h
                    where upper(coalesce(h->>'accion', '')) = 'CREAR'),
           coalesce(k2.vendedor, ''), k2.fecha_cierre, x.tipo, true
      from me.movimientos_extra x
      join me.cajas k2 on k2.id_caja = x.id_caja
     where (coalesce(x.ts, x.created_at) at time zone v_tz)::date between v_desde and v_hasta
       and k2.zona_id like 'ZONA-%'
       and (v_zona = 'TODAS' or k2.zona_id = v_zona)
       and not exists (select 1 from _rcs_k kk where kk.id_caja = x.id_caja)
  )
  select b.*,
         array_remove(array[
           case when (b.concepto || ' ' || b.obs) ~* 'cierr' then 'CIERRE' end,
           case when b.tipo = 'EGRESO'
                 and length(regexp_replace(b.concepto, '[^[:alpha:]]', '', 'g')) < 4 then 'EGRESO_SIN_CONCEPTO' end,
           case when b.editado then 'EDITADO' end,
           case when b.tipo = 'EGRESO' and b.monto > 100 then 'EGRESO_MAYOR_100' end,
           case when b.fecha_cierre is not null and b.ts > b.fecha_cierre then 'POST_CIERRE' end,
           case when b.desde_mos then 'DESDE_MOS' end,
           case when b.registrado_por <> ''
                 and upper(regexp_replace(btrim(b.registrado_por), '[[:space:]]+', ' ', 'g'))
                  <> upper(regexp_replace(btrim(b.cajero), '[[:space:]]+', ' ', 'g')) then 'OTRO_USUARIO' end,
           case when b.concepto not in ('Retiro jefe', 'Pago proveedor', 'Gasto operativo', 'Fondo cambio',
                                        'Abono deuda', 'Adelanto cliente', 'Retorno efectivo', 'Otro ingreso')
                then 'CONCEPTO_LIBRE' end,
           case when b.obs ~* '\y(desayuno|almuerzo|cena|adelanto|pasaje|men[uú])\y' then 'CONSUMO_PERSONAL' end,
           case when b.tardio then 'TARDIO_OTRA_SEMANA' end
         ], null) flags
    from b;

  -- Yapes leídos por el captor en el rango
  create temp table _rcs_y on commit drop as
  select y.id, coalesce(y.zona, '') zona, y.ts_notificacion ts, y.ts_recibido, y.monto,
         coalesce(y.pagador, '') pagador, coalesce(y.estado, '') estado, y.id_venta,
         coalesce(y.match_por, '') match_por, coalesce(y.dispositivo, '') dispositivo,
         coalesce((select jsonb_agg(jsonb_build_object('id_venta', v.id_venta, 'correlativo', coalesce(v.correlativo, ''),
                                     'total', round(coalesce(v.total, 0), 2),
                                     'vir', round(coalesce(me._monto_virtual(v.forma_pago, v.total), 0), 2),
                                     'id_caja', v.id_caja, 'vendedor', coalesce(v.vendedor, ''))
                                   order by v.fecha)
                     from (select y.id_venta x where y.id_venta is not null
                           union
                           select yv.id_venta from mos.yape_ventas yv where yv.id_yape = y.id) ids
                     join me.ventas v on v.id_venta = ids.x),
                  '[]'::jsonb) tickets
    from mos.yapes_entrantes y
   where y.dia between v_desde and v_hasta
     and (v_zona = 'TODAS' or y.zona = v_zona);

  -- ── cajas ──
  with ag as (
    select k.id_caja ag_caja,
           count(v.id_venta) filter (where v.metodo <> 'ANULADO') ventas_n,
           coalesce(sum(v.total) filter (where v.metodo <> 'ANULADO'), 0) ventas_total,
           coalesce(sum(v.total) filter (where v.metodo = 'EFECTIVO'), 0) m_efe,
           coalesce(sum(v.total) filter (where v.metodo = 'VIRTUAL'), 0) m_vir,
           coalesce(sum(v.total) filter (where v.metodo = 'CREDITO'), 0) m_cre,
           coalesce(sum(v.total) filter (where v.metodo = 'POR_COBRAR'), 0) m_pc,
           coalesce(sum(v.total) filter (where v.metodo = 'MIXTO'), 0) m_mix,
           coalesce(sum(v.total) filter (where v.fp = 'PLANILLA'), 0) planilla,
           count(v.id_venta) filter (where v.fp = 'ANULADO') anul_n,
           coalesce(sum(v.total) filter (where v.fp = 'ANULADO'), 0) anul_total,
           coalesce(max(v.total) filter (where v.fp = 'ANULADO'), 0) anul_max,
           count(v.id_venta) filter (where v.fp = 'ANULADO_CONVERSION') conv_n,
           count(v.id_venta) filter (where v.fp = 'ANULADO' and v.caja_cierre is not null
                                       and v.anul_ts > v.caja_cierre) anul_post,
           coalesce(sum(v.efe_arqueo) filter (where v.abono_caja is null), 0) efe_arqueo,
           coalesce(sum(v.efe_arqueo) filter (where v.abono_caja is not null), 0) abonado_otra,
           count(distinct (v.cliente_doc, v.cliente_nombre)) filter (where v.metodo <> 'ANULADO' and v.cli_ok) clientes_n,
           count(v.id_venta) filter (where v.metodo <> 'ANULADO' and v.vir_ver is not null and v.id_yape is not null) vv_n,
           count(v.id_venta) filter (where v.metodo <> 'ANULADO' and v.vir_ver is not null and v.id_yape is null and v.captor) vsv_n,
           coalesce(sum(v.vir_ver) filter (where v.metodo <> 'ANULADO' and v.vir_ver is not null and v.id_yape is null and v.captor), 0) vsv_total,
           count(v.id_venta) filter (where v.metodo <> 'ANULADO' and v.vir_ver is not null and v.id_yape is null and not v.captor) vsc_n,
           count(v.id_venta) filter (where v.metodo in ('CREDITO', 'POR_COBRAR') and not v.cli_ok) cred_sin_cli
      from _rcs_k k
      left join _rcs_v v on v.id_caja = k.id_caja
     group by k.id_caja
  ), ex as (
    select k.id_caja,
           count(e.id_extra) extras_n,
           coalesce(sum(e.monto) filter (where e.tipo = 'INGRESO'), 0) ing,
           coalesce(sum(e.monto) filter (where e.tipo = 'EGRESO'), 0) egr,
           coalesce(sum(e.monto) filter (where e.tipo = 'INGRESO_VIRTUAL'), 0) ing_v,
           coalesce(sum(e.monto) filter (where e.tipo = 'EGRESO_VIRTUAL'), 0) egr_v,
           coalesce(sum(e.monto) filter (where e.tipo_raw = 'INGRESO'), 0) arq_ing,
           coalesce(sum(e.monto) filter (where e.tipo_raw = 'EGRESO'), 0) arq_egr,
           count(e.id_extra) filter (where 'CIERRE' = any (e.flags)) ext_cierre,
           count(e.id_extra) filter (where exists (select 1 from unnest(e.flags) f
                                                    where mos._control_caja_nivel(f) = 'MEDIA')) ext_media,
           count(e.id_extra) filter (where 'POST_CIERRE' = any (e.flags)) ext_post,
           count(e.id_extra) filter (where e.desde_mos) ext_mos
      from _rcs_k k
      left join _rcs_e e on e.id_caja = k.id_caja
     group by k.id_caja
  ), ya as (
    -- cada Yape sin venta se atribuye a UNA caja: la de su zona abierta en ese momento con apertura más reciente
    select distinct on (y.id) y.id, k.id_caja
      from mos.yapes_entrantes y
      join _rcs_k k
        on y.zona = k.zona_id
       and y.ts_notificacion >= k.fecha_apertura
       and y.ts_notificacion <= coalesce(k.fecha_cierre, v_now)
     where y.estado in ('NUEVO', 'AMBIGUO') and y.monto is not null
       and y.ts_notificacion < v_now - interval '30 minutes'
       and y.ts_notificacion >= (select min(fecha_apertura) from _rcs_k)
     order by y.id, k.fecha_apertura desc, k.id_caja
  ), ys as (
    select ya.id_caja, count(*) yapes_sin_venta from ya group by ya.id_caja
  ), za as (
    -- promedio de anulaciones por caja de cada zona en el rango (para la alerta relativa)
    select k.zona_id, avg(coalesce(ag2.anul_n, 0)) prom_anul
      from _rcs_k k join ag ag2 on ag2.ag_caja = k.id_caja
     group by k.zona_id
  ), c as (
    select k.*, ag.*, ex.extras_n, ex.ing, ex.egr, ex.ing_v, ex.egr_v, ex.ext_cierre, ex.ext_media,
           ex.ext_post, ex.ext_mos, coalesce(ys.yapes_sin_venta, 0) yapes_sin_venta,
           coalesce(za.prom_anul, 0) prom_anul,
           round(k.monto_inicial + ag.efe_arqueo + ex.arq_ing - ex.arq_egr, 2) esperado
      from _rcs_k k
      join ag on ag.ag_caja = k.id_caja
      join ex on ex.id_caja = k.id_caja
      left join ys on ys.id_caja = k.id_caja
      left join za on za.zona_id = k.zona_id
  ), al as (
    select c.id_caja, coalesce(jsonb_agg(jsonb_build_object('codigo', a.codigo,
                                   'nivel', coalesce(a.nivel, mos._control_caja_nivel(a.codigo)), 'texto', a.texto)
                                   order by case coalesce(a.nivel, mos._control_caja_nivel(a.codigo))
                                              when 'ALTA' then 1 when 'MEDIA' then 2 else 3 end, a.codigo)
                                 filter (where a.codigo is not null), '[]'::jsonb) alertas
      from c
      left join lateral (values
        (case when c.estado = 'ABIERTA' and v_now - c.fecha_apertura > interval '14 hours' then 'ABIERTA_MAS_14H' end, null::text,
         'Caja abierta hace ' || round(extract(epoch from (v_now - c.fecha_apertura)) / 3600, 1) || ' h'),
        (case when c.estado = 'ABIERTA' and c.dia < v_hoy then 'ABIERTA_DIA_ANTERIOR' end, null,
         'Caja abierta desde el ' || to_char(c.dia, 'DD/MM') || ' y no se cerró'),
        (case when c.estado <> 'ABIERTA' and c.monto_final is not null and round(c.monto_final - c.esperado, 2) <> 0
              then 'DIFERENCIA' end,
         case when abs(c.monto_final - c.esperado) >= 5 then 'ALTA' else 'MEDIA' end,
         'Cerró con S/ ' || to_char(c.monto_final, 'FM999999990.00') || ' y el arqueo da S/ '
           || to_char(c.esperado, 'FM999999990.00') || ' (diferencia S/ '
           || to_char(round(c.monto_final - c.esperado, 2), 'FM999999990.00') || ')'),
        (case when c.esperado < 0 then 'ESPERADO_NEGATIVO' end, null,
         'El efectivo esperado es negativo: S/ ' || to_char(c.esperado, 'FM999999990.00')),
        (case when c.ext_cierre > 0 then 'EXTRA_CIERRE' end, null,
         c.ext_cierre || ' extra(s) mencionan el cierre: posible doble resta del efectivo'),
        (case when c.ext_media > 0 then 'EXTRAS_OBSERVADOS' end, null,
         c.ext_media || ' extra(s) observados (editados, sin concepto, egreso > S/ 100 o después del cierre)'),
        (case when c.vsv_n > 0 then 'VIRTUAL_SIN_YAPE' end, null,
         c.vsv_n || ' venta(s) virtual(es) sin Yape que las verifique (S/ ' || to_char(c.vsv_total, 'FM999999990.00') || ')'),
        (case when c.yapes_sin_venta > 0 then 'YAPE_SIN_VENTA' end, null,
         c.yapes_sin_venta || ' Yape(s) recibidos con la caja abierta y sin venta después de 30 min'),
        (case when (c.anul_n >= 3
                    and (c.anul_n > 2 * c.prom_anul or c.anul_n > 0.05 * (c.ventas_n + c.anul_n)))
                    or c.anul_max > 50 then 'ANULACIONES' end, null,
         c.anul_n || ' anulación(es) por S/ ' || to_char(c.anul_total, 'FM999999990.00')
           || ' (promedio de la zona ' || to_char(round(c.prom_anul, 1), 'FM9990.0') || ' por caja; '
           || to_char(round(100.0 * c.anul_n / greatest(c.ventas_n + c.anul_n, 1), 1), 'FM9990.0') || ' % de los tickets)'
           || case when c.anul_max > 50 then ' · una de S/ ' || to_char(c.anul_max, 'FM999999990.00') else '' end),
        (case when c.cred_sin_cli > 0 then 'CREDITO_SIN_CLIENTE' end, null,
         c.cred_sin_cli || ' venta(s) a crédito o por cobrar sin cliente identificado'),
        (case when c.ext_post + c.anul_post > 0 then 'POST_CIERRE' end, null,
         'Después del cierre: ' || c.ext_post || ' extra(s) y ' || c.anul_post || ' anulación(es)'),
        (case when c.estado = 'CERRADA_AUTO' then 'CERRADA_AUTO' end, null,
         'La caja la cerró el sistema, no el cajero'),
        (case when c.vsc_n > 0 then 'SIN_CAPTOR' end, null,
         c.vsc_n || ' venta(s) virtual(es) sin captor Yape en la zona ese día: no se pueden verificar'),
        (case when c.ext_mos > 0 then 'EXTRA_DESDE_MOS' end, null,
         c.ext_mos || ' extra(s) creados desde MOS')
      ) a(codigo, nivel, texto) on true
     group by c.id_caja
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id_caja', c.id_caja, 'zona_id', c.zona_id, 'vendedor', c.vendedor, 'estacion', c.estacion,
           'estado', c.estado, 'fecha_apertura', c.fecha_apertura, 'fecha_cierre', c.fecha_cierre,
           'horas', round(extract(epoch from (coalesce(c.fecha_cierre, v_now) - c.fecha_apertura)) / 3600, 1),
           'monto_inicial', c.monto_inicial, 'monto_final', c.monto_final,
           'esperado_efectivo', c.esperado,
           'diferencia', case when c.estado <> 'ABIERTA' and c.monto_final is not null
                              then round(c.monto_final - c.esperado, 2) end,
           'ventas_n', c.ventas_n, 'ventas_total', round(c.ventas_total, 2),
           'por_metodo', jsonb_build_object('EFECTIVO', round(c.m_efe, 2), 'VIRTUAL', round(c.m_vir, 2),
                                            'CREDITO', round(c.m_cre, 2), 'POR_COBRAR', round(c.m_pc, 2),
                                            'MIXTO', round(c.m_mix, 2)),
           'anulados_n', c.anul_n, 'anulados_total', round(c.anul_total, 2),
           'extras_n', c.extras_n, 'extras_ingreso', round(c.ing, 2), 'extras_egreso', round(c.egr, 2),
           'clientes_n', c.clientes_n,
           'virtual_verificado_n', c.vv_n, 'virtual_sin_verificar_n', c.vsv_n,
           'virtual_sin_verificar_total', round(c.vsv_total, 2),
           'alertas', al.alertas,
           'revision', (select jsonb_build_object('estado', r.estado, 'nota', r.nota, 'usuario', r.usuario, 'ts', r.ts)
                          from mos.control_caja_revision r where r.tipo = 'CAJA' and r.ref = c.id_caja),
           'efectivo_ventas', round(c.efe_arqueo, 2),
           'abonado_en_otra_caja', round(c.abonado_otra, 2),
           'extras_ingreso_virtual', round(c.ing_v, 2), 'extras_egreso_virtual', round(c.egr_v, 2),
           'planilla', round(c.planilla, 2), 'conversiones_n', c.conv_n,
           'virtual_sin_captor_n', c.vsc_n
         ) order by c.fecha_apertura, c.zona_id), '[]'::jsonb)
    into v_cajas
    from c join al on al.id_caja = c.id_caja;

  -- ── extras ──
  select coalesce(jsonb_agg(jsonb_build_object(
           'id_extra', e.id_extra, 'id_caja', e.id_caja, 'zona_id', e.zona_id, 'ts', e.ts, 'tipo', e.tipo,
           'monto', e.monto, 'concepto', e.concepto, 'obs', e.obs, 'registrado_por', e.registrado_por,
           'editado', e.editado, 'flags', to_jsonb(e.flags),
           'nivel', (select case when bool_or(mos._control_caja_nivel(f) = 'ALTA') then 'ALTA'
                                 when bool_or(mos._control_caja_nivel(f) = 'MEDIA') then 'MEDIA'
                                 when count(*) > 0 then 'BAJA' end
                       from unnest(e.flags) f),
           'desde_mos', e.desde_mos,
           'tardio', e.tardio,
           'revision', (select jsonb_build_object('estado', r.estado, 'nota', r.nota, 'usuario', r.usuario, 'ts', r.ts)
                          from mos.control_caja_revision r where r.tipo = 'EXTRA' and r.ref = e.id_extra)
         ) order by e.ts nulls last, e.id_extra), '[]'::jsonb)
    into v_extras
    from _rcs_e e;

  -- ── ventas ──
  select coalesce(jsonb_agg(jsonb_build_object(
           'id_venta', v.id_venta, 'id_caja', v.id_caja, 'zona_id', v.zona_id, 'fecha', v.fecha,
           'vendedor', v.vendedor, 'correlativo', v.correlativo, 'tipo_doc', v.tipo_doc,
           'cliente_doc', v.cliente_doc, 'cliente_nombre', v.cliente_nombre, 'total', v.total,
           'forma_pago', v.forma_pago, 'metodo', v.metodo, 'efe', v.efe, 'vir', v.vir,
           'verificado', case when v.metodo = 'ANULADO' or v.vir_ver is null then null
                              when v.id_yape is not null then true
                              when not v.captor then null
                              else false end,
           'estado_virtual', case when v.metodo <> 'ANULADO' and v.vir_ver is null and v.vir_raw is not null
                                  then 'COBRO_ABONO'
                                  when v.metodo = 'ANULADO' or v.vir_ver is null then null
                                  when v.id_yape is not null then 'VERIFICADO'
                                  when not v.captor then 'SIN_CAPTOR'
                                  else 'SIN_VERIFICAR' end,
           'id_yape', v.id_yape, 'nf_estado', v.nf_estado,
           'cobrado_en', v.abono_caja,
           'flags', to_jsonb(array_remove(array[
              case when v.metodo in ('CREDITO', 'POR_COBRAR') and not v.cli_ok then 'CREDITO_SIN_CLIENTE' end,
              case when v.metodo <> 'ANULADO' and v.vir_ver is not null and v.id_yape is null and v.captor then 'VIRTUAL_SIN_YAPE' end,
              case when v.fp = 'ANULADO' and v.total > 50 then 'ANULADO_MAYOR_50' end,
              case when v.fp = 'ANULADO' and v.caja_cierre is not null
                    and v.anul_ts > v.caja_cierre then 'ANULADO_POST_CIERRE' end,
              case when v.anul_ts_ilegible then 'TS_ILEGIBLE' end,
              case when v.abono_caja is not null then 'COBRADO_EN_OTRA_CAJA' end], null)),
           'yapes', case when v.id_yape is not null then
                      (select jsonb_agg(jsonb_build_object('id', y.id, 'monto', y.monto, 'pagador', coalesce(y.pagador, ''),
                                                           'ts', y.ts_notificacion))
                         from mos.yapes_entrantes y where y.id = v.id_yape) end,
           'candidatos', case when v.metodo <> 'ANULADO' and v.vir_ver is not null and v.id_yape is null then
                           (select coalesce(jsonb_agg(jsonb_build_object('id', cd.id, 'monto', cd.monto, 'pagador', cd.pagador,
                                                                         'ts', cd.ts, 'combo_con', cd.combo_con,
                                                                         'combo_yape', cd.combo_yape)
                                                      order by abs(extract(epoch from (cd.ts - v.fecha)))), '[]'::jsonb)
                              from _rcs_cand cd where cd.id_venta = v.id_venta) end,
           'revision', (select jsonb_build_object('estado', r.estado, 'nota', r.nota, 'usuario', r.usuario, 'ts', r.ts)
                          from mos.control_caja_revision r where r.tipo = 'VENTA' and r.ref = v.id_venta)
         ) order by v.fecha, v.id_venta), '[]'::jsonb)
    into v_ventas
    from _rcs_v v
   where not v.tardio
     and (not v_lite
      or v.metodo <> 'EFECTIVO'
      or (v.metodo in ('CREDITO', 'POR_COBRAR') and not v.cli_ok)
      or v.abono_caja is not null
      or exists (select 1 from mos.control_caja_revision r where r.tipo = 'VENTA' and r.ref = v.id_venta));

  -- ── anulados (solo ANULADO real; ANULADO_CONVERSION no es anulación) ──
  select coalesce(jsonb_agg(jsonb_build_object(
           'id_venta', v.id_venta, 'id_caja', v.id_caja, 'zona_id', v.zona_id, 'fecha', v.fecha,
           'vendedor', v.vendedor, 'correlativo', v.correlativo, 'cliente_nombre', v.cliente_nombre,
           'total', v.total,
           'anulado_por', nullif(btrim(coalesce(v.anul_hist->>'usuario', '')), ''),
           'anulado_ts', v.anul_ts,
           'anulado_ts_raw', v.anul_hist->>'ts',
           'tardio', v.tardio,
           'flags', to_jsonb(array_remove(array[
              case when v.total > 50 then 'ANULADO_MAYOR_50' end,
              case when v.caja_cierre is not null and v.anul_ts > v.caja_cierre then 'ANULADO_POST_CIERRE' end,
              case when v.anul_ts_ilegible then 'TS_ILEGIBLE' end,
              case when v.anul_hist is null then 'SIN_HISTORIAL' end,
              case when v.tardio then 'TARDIO_OTRA_SEMANA' end], null)),
           'motivo', coalesce(nullif(btrim(coalesce(v.anul_hist->>'motivo', '')), ''), nullif(btrim(v.obs), '')),
           'antes', (select c->>'antes' from jsonb_array_elements(case when jsonb_typeof(v.anul_hist->'cambios') = 'array'
                                                                      then v.anul_hist->'cambios' else '[]'::jsonb end) c
                      where upper(coalesce(c->>'despues', '')) like 'ANULADO%' limit 1),
           'autorizado_por', case jsonb_typeof(v.anul_hist->'autorizadoPor')
                               when 'object' then v.anul_hist->'autorizadoPor'->>'nombre'
                               when 'string' then v.anul_hist->>'autorizadoPor' end,
           'source', v.anul_hist->>'source',
           'sin_historial', v.anul_hist is null,
           'revision', (select jsonb_build_object('estado', r.estado, 'nota', r.nota, 'usuario', r.usuario, 'ts', r.ts)
                          from mos.control_caja_revision r where r.tipo = 'ANULADO' and r.ref = v.id_venta)
         ) order by v.fecha, v.id_venta), '[]'::jsonb)
    into v_anul
    from _rcs_v v
   where v.fp = 'ANULADO';

  -- ── Yapes ──
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', y.id, 'zona', y.zona, 'ts', y.ts, 'ts_recibido', y.ts_recibido, 'monto', y.monto,
           'pagador', y.pagador, 'estado', y.estado, 'id_venta', y.id_venta, 'match_por', y.match_por,
           'dispositivo', y.dispositivo, 'tickets', y.tickets,
           'suma_tickets', s.suma,
           'diferencia', case when jsonb_array_length(y.tickets) > 0 and y.monto is not null
                              then round(y.monto - s.suma, 2) end,
           'flags', to_jsonb(array_remove(array[
              case when y.estado in ('NUEVO', 'AMBIGUO') and y.monto is not null
                    and y.ts < v_now - interval '30 minutes' then 'SIN_VENTA_30M' end,
              case when jsonb_array_length(y.tickets) > 0 and y.monto is not null
                    and round(y.monto, 1) <> round(s.suma, 1) then 'DIFERENCIA_TICKETS' end], null)),
           'revision', (select jsonb_build_object('estado', r.estado, 'nota', r.nota, 'usuario', r.usuario, 'ts', r.ts)
                          from mos.control_caja_revision r where r.tipo = 'YAPE' and r.ref = y.id::text)
         ) order by y.ts, y.id), '[]'::jsonb)
    into v_yapes
    from _rcs_y y
    cross join lateral (select round(coalesce(sum((t->>'vir')::numeric), 0), 2) suma
                          from jsonb_array_elements(y.tickets) t) s;

  -- ── tickets virtuales ──
  select coalesce(jsonb_agg(jsonb_build_object(
           'id_venta', v.id_venta, 'id_caja', v.id_caja, 'zona_id', v.zona_id, 'fecha', v.fecha,
           'vendedor', v.vendedor, 'correlativo', v.correlativo, 'cliente_nombre', v.cliente_nombre,
           'vir', round(v.vir_ver, 2),
           'estado', case when v.id_yape is not null then 'VERIFICADO'
                          when not v.captor then 'SIN_CAPTOR' else 'SIN_VERIFICAR' end,
           'id_yape', v.id_yape,
           'candidatos_n', case when v.id_yape is null
                                then (select count(*) from _rcs_cand cd where cd.id_venta = v.id_venta) else 0 end
         ) order by v.fecha, v.id_venta), '[]'::jsonb)
    into v_tv
    from _rcs_v v
   where v.metodo <> 'ANULADO' and v.vir_ver is not null;

  -- ── clientes por caja (identificados; sin VARIOS/66666) ──
  select coalesce(jsonb_agg(jsonb_build_object('id_caja', g.id_caja, 'cliente_doc', g.cliente_doc,
                                               'cliente_nombre', g.cliente_nombre, 'n', g.n, 'total', g.total)
                            order by g.id_caja, g.total desc), '[]'::jsonb)
    into v_cli
    from (select v.id_caja, v.cliente_doc, v.cliente_nombre, count(*) n, round(sum(v.total), 2) total
            from _rcs_v v where v.metodo <> 'ANULADO' and v.cli_ok
           group by 1, 2, 3) g;

  -- ── resumen ──
  select jsonb_build_object(
    'cajas_abiertas', (select count(*) from _rcs_k where estado = 'ABIERTA'),
    'cajas_cerradas', (select count(*) from _rcs_k where estado <> 'ABIERTA'),
    'ventas_n', count(*) filter (where v.metodo <> 'ANULADO'),
    'ventas_total', round(coalesce(sum(v.total) filter (where v.metodo <> 'ANULADO'), 0), 2),
    'efectivo', round(coalesce(sum(v.total) filter (where v.metodo = 'EFECTIVO'), 0), 2),
    'virtual', round(coalesce(sum(v.total) filter (where v.metodo = 'VIRTUAL'), 0), 2),
    'credito', round(coalesce(sum(v.total) filter (where v.metodo = 'CREDITO'), 0), 2),
    'por_cobrar', round(coalesce(sum(v.total) filter (where v.metodo = 'POR_COBRAR'), 0), 2),
    'mixto_efe', round(coalesce(sum(v.efe) filter (where v.metodo = 'MIXTO'), 0), 2),
    'mixto_vir', round(coalesce(sum(v.vir) filter (where v.metodo = 'MIXTO'), 0), 2),
    'planilla', round(coalesce(sum(v.total) filter (where v.fp = 'PLANILLA'), 0), 2),
    'anulados_n', count(*) filter (where v.fp = 'ANULADO' and not v.tardio),
    'anulados_total', round(coalesce(sum(v.total) filter (where v.fp = 'ANULADO' and not v.tardio), 0), 2),
    'conversiones_n', count(*) filter (where v.fp = 'ANULADO_CONVERSION'),
    'tardios_anulados_n', count(*) filter (where v.tardio),
    'tardios_extras_n', (select count(*) from _rcs_e where tardio),
    'extras_ingreso', (select round(coalesce(sum(monto), 0), 2) from _rcs_e where tipo = 'INGRESO' and not tardio),
    'extras_egreso', (select round(coalesce(sum(monto), 0), 2) from _rcs_e where tipo = 'EGRESO' and not tardio),
    'extras_virtual_neto', (select round(coalesce(sum(case when tipo = 'INGRESO_VIRTUAL' then monto
                                                           when tipo = 'EGRESO_VIRTUAL' then -monto else 0 end), 0), 2)
                              from _rcs_e where not tardio),
    'extras_no_permitidos_n', (select count(*) from _rcs_e e
                                where exists (select 1 from unnest(e.flags) f
                                               where mos._control_caja_nivel(f) in ('ALTA', 'MEDIA'))),
    'yapes_sin_match_n', (select count(*) from _rcs_y where estado in ('NUEVO', 'AMBIGUO') and monto is not null),
    'yapes_sin_match_total', (select round(coalesce(sum(monto), 0), 2) from _rcs_y
                               where estado in ('NUEVO', 'AMBIGUO') and monto is not null),
    'yapes_captor_n', (select count(*) from _rcs_y where monto is not null),
    'yapes_captor_total', (select round(coalesce(sum(monto), 0), 2) from _rcs_y where monto is not null),
    'virtual_verificado_n', count(*) filter (where v.metodo <> 'ANULADO' and v.vir_ver is not null and v.id_yape is not null),
    'virtual_verificado_total', round(coalesce(sum(v.vir_ver) filter (where v.metodo <> 'ANULADO' and v.vir_ver is not null
                                                                        and v.id_yape is not null), 0), 2),
    'virtual_sin_verificar_n', count(*) filter (where v.metodo <> 'ANULADO' and v.vir_ver is not null
                                                  and v.id_yape is null and v.captor),
    'virtual_sin_verificar_total', round(coalesce(sum(v.vir_ver) filter (where v.metodo <> 'ANULADO' and v.vir_ver is not null
                                                                           and v.id_yape is null and v.captor), 0), 2),
    'virtual_sin_captor_n', count(*) filter (where v.metodo <> 'ANULADO' and v.vir_ver is not null
                                               and v.id_yape is null and not v.captor),
    'virtual_sin_captor_total', round(coalesce(sum(v.vir_ver) filter (where v.metodo <> 'ANULADO' and v.vir_ver is not null
                                                                        and v.id_yape is null and not v.captor), 0), 2),
    'alertas_n', (select count(*) from jsonb_array_elements(v_cajas) c, jsonb_array_elements(c->'alertas') a
                   where a->>'nivel' in ('ALTA', 'MEDIA')),
    'alertas_alta_n', (select count(*) from jsonb_array_elements(v_cajas) c, jsonb_array_elements(c->'alertas') a
                        where a->>'nivel' = 'ALTA'))
    into v_res
    from _rcs_v v;

  return jsonb_build_object(
    'ok', true,
    'desde', v_desde, 'hasta', v_hasta, 'zona', v_zona, 'generado_ts', v_now,
    'resumen', v_res,
    'cajas', v_cajas, 'extras', v_extras, 'ventas', v_ventas, 'anulados', v_anul,
    'yapes', v_yapes, 'tickets_virtuales', v_tv, 'clientes', v_cli);
end; $function$;

create or replace function mos.control_caja_marcar(p jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_usr  text := btrim(coalesce(p->>'usuario', ''));
  v_tipo text := upper(btrim(coalesce(p->>'tipo', '')));
  v_ref  text := btrim(coalesce(p->>'ref', ''));
  v_borrar boolean := p ? 'estado' and jsonb_typeof(p->'estado') = 'null';
  v_est  text := case when jsonb_typeof(p->'estado') = 'string' then upper(btrim(p->>'estado')) end;
  v_nota text := left(nullif(btrim(coalesce(p->>'nota', '')), ''), 500);
  v_sub  text := nullif(coalesce(me.jwt_sub(), ''), '');
  v_ses  text;
  v_coin boolean;
  v_ok   boolean;
  v_old  jsonb;
  v_row  mos.control_caja_revision%rowtype;
begin
  if coalesce(me.jwt_app(), '') <> 'MOS' then
    return jsonb_build_object('ok', false, 'error', 'NO_AUTORIZADO');
  end if;
  if v_usr = '' or not mos._control_caja_rol_ok(v_usr) then
    return jsonb_build_object('ok', false, 'error', 'ROL_NO_AUTORIZADO');
  end if;
  if v_tipo not in ('CAJA', 'EXTRA', 'VENTA', 'YAPE', 'ANULADO') or v_ref = '' then
    return jsonb_build_object('ok', false, 'error', 'PARAMETROS_INVALIDOS');
  end if;
  if not v_borrar and coalesce(v_est, '') not in ('OK', 'OBSERVADO') then
    return jsonb_build_object('ok', false, 'error', 'ESTADO_INVALIDO');
  end if;

  -- usuario declarado vs equipo del JWT (sub = id del dispositivo; ultima_sesion = quién entró en él)
  if v_sub is not null then
    select nullif(btrim(coalesce(d.ultima_sesion, '')), '') into v_ses
      from mos.dispositivos d where d.id_dispositivo = v_sub limit 1;
    if v_ses is not null then
      v_coin := upper(regexp_replace(v_usr, '[[:space:]]+', ' ', 'g')) = upper(regexp_replace(v_ses, '[[:space:]]+', ' ', 'g'))
             or upper(split_part(v_usr, ' ', 1)) = upper(split_part(v_ses, ' ', 1));
    end if;
  end if;

  v_ok := case v_tipo
    when 'CAJA'    then exists (select 1 from me.cajas where id_caja = v_ref)
    when 'EXTRA'   then exists (select 1 from me.movimientos_extra where id_extra = v_ref)
    when 'VENTA'   then exists (select 1 from me.ventas where id_venta = v_ref)
    when 'ANULADO' then exists (select 1 from me.ventas where id_venta = v_ref and upper(coalesce(forma_pago, '')) like 'ANULADO%')
    when 'YAPE'    then v_ref ~ '^[0-9]{1,18}$' and exists (select 1 from mos.yapes_entrantes where id = v_ref::bigint)
  end;
  if not v_ok then
    return jsonb_build_object('ok', false, 'error', 'REFERENCIA_NO_EXISTE');
  end if;

  perform pg_advisory_xact_lock(hashtext('ctrlcaja:' || v_tipo || ':' || v_ref));
  select to_jsonb(r) into v_old from mos.control_caja_revision r where r.tipo = v_tipo and r.ref = v_ref;

  if v_borrar then
    delete from mos.control_caja_revision where tipo = v_tipo and ref = v_ref;
    if v_old is not null then
      insert into mos.control_caja_revision_log (tipo, ref, accion, estado, nota, usuario, antes,
                                                 jwt_sub, sesion_equipo, coincide_sesion)
        values (v_tipo, v_ref, 'BORRAR', null, v_nota, v_usr, v_old, v_sub, v_ses, v_coin);
    end if;
    return jsonb_build_object('ok', true, 'borrado', v_old is not null, 'tipo', v_tipo, 'ref', v_ref, 'revision', null);
  end if;

  insert into mos.control_caja_revision (tipo, ref, estado, nota, usuario, ts)
    values (v_tipo, v_ref, v_est, v_nota, v_usr, now())
  on conflict (tipo, ref) do update
    set estado = excluded.estado, nota = excluded.nota, usuario = excluded.usuario, ts = excluded.ts
  returning * into v_row;

  insert into mos.control_caja_revision_log (tipo, ref, accion, estado, nota, usuario, antes,
                                             jwt_sub, sesion_equipo, coincide_sesion)
    values (v_tipo, v_ref, 'MARCAR', v_est, v_nota, v_usr, v_old, v_sub, v_ses, v_coin);

  return jsonb_build_object('ok', true, 'tipo', v_tipo, 'ref', v_ref,
    'revision', jsonb_build_object('estado', v_row.estado, 'nota', v_row.nota, 'usuario', v_row.usuario, 'ts', v_row.ts));
end; $function$;

revoke all on function mos.reporte_cajas_semana(jsonb) from public, anon;
revoke all on function mos.control_caja_marcar(jsonb) from public, anon;
grant execute on function mos.reporte_cajas_semana(jsonb) to authenticated, service_role;
grant execute on function mos.control_caja_marcar(jsonb) to authenticated, service_role;
