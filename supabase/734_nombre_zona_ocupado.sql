-- 734 · GUARD DE NOMBRE DUPLICADO EN LA MISMA ZONA (wizard de MosExpress)
--
-- Pedido del dueño, literal: "si mañana vienen los dos Jesus, por buena práctica el admin le
-- pide usar otro nombre, pero por programa tú lo obligas: le dices 'ya existe JESUS en esta
-- zona'. Si eres otra persona usa otro nombre; si eres el mismo, usa la extensión de dispositivo".
--
-- POR QUÉ EXISTE (el daño real): la identidad de un cajero/vendedor de ME es
-- `MEX:<NOMBRE>|<ZONA>` y de ahí sale el id_dia de mos.liquidaciones_dia. Dos personas
-- distintas con el MISMO nombre en la MISMA zona el MISMO día caen en la MISMA fila de
-- liquidación: la venta cobrada, el bono y la comisión de ambos se mezclan en una sola tarjeta
-- (es el mismo agujero que cerró el 733 para las tildes, pero por el lado de la entrada).
--
-- QUÉ NO ES CONFLICTO (importante, esto es lo que hace usable al guard):
--   · El mismo nombre en ZONAS DISTINTAS convive y es correcto (hoy MIA y SHADYA existen en
--     ZONA-01 y ZONA-02 sin pisarse). Solo choca mismo nombre + misma zona + mismo día.
--   · El MISMO equipo reconectando (o el 2º equipo ya atado por extensión de dispositivo):
--     si el deviceId consultante ya figura entre los equipos de esa persona-día, NO hay
--     conflicto — es la misma persona, y así debe seguir siendo.
--   · Una sesión del día que YA está cerrada (turno anterior). Los equipos se comparten entre
--     turnos (536 casos/30d) y bloquear ahí dejaría gente sin poder trabajar. La regla de oro
--     es que nadie se quede parado por un chequeo: solo se bloquea contra sesión VIVA.
--
-- SESIÓN VIVA = liquidaciones_dia.estado_sesion='ACTIVA' — la MISMA definición que usa
-- mos.extension_activos_zona para pintar los avatares 🟢 del wizard y la que exige
-- mos.pedir_extension para dejar atar un 2º equipo. Es deliberado que sea la misma: si el guard
-- bloqueara con un criterio más ancho que el de la extensión, el aviso ofrecería una salida
-- ("soy yo, en otro equipo") que el servidor después rechazaría, y la persona quedaría atrapada.
-- Se suma un solo caso extra: la fila SIN estado_sesion (dato viejo/incompleto) pero con un
-- equipo suyo ACTIVA en mos.accesos_dispositivos. Una fila explícitamente CERRADA o
-- FORZADA_11PM NUNCA bloquea, aunque su tablet siga pingueando (deriva real de producción).
--
-- La RPC solo INFORMA (STABLE, no escribe nada). Quien decide es el wizard; si esta RPC falla
-- o tarda, ME deja pasar igual.
begin;

create or replace function mos.nombre_zona_ocupado(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_nombre    text;
  v_zona      text;
  v_zona_cmp  text;
  v_dev       text := btrim(coalesce(p->>'deviceId',''));
  v_dia       date;
  r           record;
  v_equipos   int;
  v_activos   int;
  v_mio       boolean;
  v_viva      boolean;
  v_ppal      text;
  v_sug       jsonb;
begin
  -- Solo apps del ecosistema con token (ME llama esto con su JWT de dispositivo).
  if coalesce(me.jwt_app(),'') = '' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- Normalización IDÉNTICA a la del wizard (_wizNombreNorm, 2.8.278): MAYÚSCULAS, sin tildes
  -- ni diéresis (la Ñ cae en N igual que el NFD del navegador), solo letras y espacios simples.
  v_nombre := btrim(regexp_replace(
                regexp_replace(
                  upper(translate(coalesce(p->>'nombre',''),
                                  'ÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇáàäâãéèëêíìïîóòöôõúùüûñç',
                                  'AAAAAEEEEIIIIOOOOOUUUUNCAAAAAEEEEIIIIOOOOOUUUUNC')),
                  '[^A-Z ]+', '', 'g'),
                ' {2,}', ' ', 'g'));
  v_zona   := upper(btrim(coalesce(p->>'zona','')));
  -- ZONA-02 / ZONA_02 / zona 02 son la misma tienda: se comparan sin separadores.
  v_zona_cmp := regexp_replace(v_zona, '[^A-Z0-9]', '', 'g');

  if v_nombre = '' or v_zona_cmp = '' then
    return jsonb_build_object('ok', true, 'ocupado', false, 'motivo', 'SIN_DATOS');
  end if;

  begin
    v_dia := coalesce(nullif(btrim(coalesce(p->>'fecha','')),'')::date,
                      (now() at time zone 'America/Lima')::date);
  exception when others then
    v_dia := (now() at time zone 'America/Lima')::date;
  end;

  -- El que ya está adentro: fila de HOY con el MISMO nombre normalizado en la MISMA zona.
  -- Se compara sobre `nombre` normalizado (no sobre el texto crudo de id_personal) para que
  -- una fila vieja "Jesús" también cuente: en la tienda los dos se llaman igual.
  select l.id_dia, l.id_personal, l.nombre, l.zona, l.rol, l.estado_sesion,
         l.hora_ingreso, l.ultima_conexion, l.device_id
    into r
  from mos.liquidaciones_dia l
  where (l.fecha at time zone 'America/Lima')::date = v_dia
    and coalesce(l.app_origen,'') = 'mosExpress'
    and regexp_replace(upper(coalesce(l.zona,'')), '[^A-Z0-9]', '', 'g') = v_zona_cmp
    and btrim(regexp_replace(
          regexp_replace(
            upper(translate(coalesce(l.nombre,''),
                            'ÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇáàäâãéèëêíìïîóòöôõúùüûñç',
                            'AAAAAEEEEIIIIOOOOOUUUUNCAAAAAEEEEIIIIOOOOOUUUUNC')),
            '[^A-Z ]+', '', 'g'),
          ' {2,}', ' ', 'g')) = v_nombre
  order by (upper(coalesce(l.estado_sesion,'')) = 'ACTIVA') desc,
           l.hora_ingreso desc nulls last
  limit 1;

  if not found then
    return jsonb_build_object('ok', true, 'ocupado', false, 'motivo', 'LIBRE',
                              'nombre', v_nombre, 'zona', v_zona);
  end if;

  -- Equipos de esa persona-día (aquí es donde la extensión de dispositivo agrupa los 2 equipos).
  select count(*)::int,
         count(*) filter (where upper(coalesce(a.estado,'')) = 'ACTIVA')::int,
         bool_or(a.device_id = v_dev),
         bool_or(upper(coalesce(a.estado,'')) = 'ACTIVA'),
         min(a.device_id) filter (where a.es_principal)
    into v_equipos, v_activos, v_mio, v_viva, v_ppal
  from mos.accesos_dispositivos a
  where a.id_dia = r.id_dia;

  v_equipos := coalesce(v_equipos, 0);
  v_activos := coalesce(v_activos, 0);
  v_mio     := coalesce(v_mio, false) or (v_dev <> '' and r.device_id = v_dev);
  -- viva: ACTIVA declarada, o fila sin estado (dato incompleto) con un equipo suyo ACTIVA.
  -- CERRADA / FORZADA_11PM jamás bloquean.
  v_viva    := (upper(coalesce(r.estado_sesion,'')) = 'ACTIVA')
               or (upper(coalesce(r.estado_sesion,'')) not in ('CERRADA','FORZADA_11PM')
                   and coalesce(v_viva, false));
  v_ppal    := coalesce(v_ppal, r.device_id);
  if v_equipos = 0 then v_equipos := 1; end if;              -- la fila de liquidación ya implica 1 equipo
  if v_activos = 0 and v_viva then v_activos := 1; end if;

  -- ── NO es conflicto ──────────────────────────────────────────────────────────────────────
  -- (a) el equipo que pregunta YA es de esa persona-día: es él reconectando o su extensión.
  if v_dev <> '' and v_mio then
    return jsonb_build_object('ok', true, 'ocupado', false, 'motivo', 'MI_EQUIPO',
                              'nombre', v_nombre, 'zona', v_zona, 'idDia', r.id_dia);
  end if;
  -- (b) el turno de ese nombre ya cerró: los equipos se comparten entre turnos, no se bloquea.
  if not v_viva then
    return jsonb_build_object('ok', true, 'ocupado', false, 'motivo', 'SESION_CERRADA',
                              'nombre', v_nombre, 'zona', v_zona, 'idDia', r.id_dia,
                              'estadoSesion', upper(coalesce(r.estado_sesion,'')));
  end if;

  -- ── SÍ es conflicto: otro equipo quiere entrar con un nombre que ya está trabajando acá ──
  -- Sugerencias: el mismo nombre + una inicial libre (el wizard solo acepta letras y espacios,
  -- por eso nunca se sugiere "JESUS 2"). Se descartan las que ya existan hoy en esta zona.
  select coalesce(jsonb_agg(c.cand order by c.ord), '[]'::jsonb)
    into v_sug
  from (
    select v_nombre || ' ' || l.letra as cand, l.ord
    from (select chr(64 + g) letra, g ord from generate_series(1, 26) g) l
    where not exists (
      select 1 from mos.liquidaciones_dia x
      where (x.fecha at time zone 'America/Lima')::date = v_dia
        and regexp_replace(upper(coalesce(x.zona,'')), '[^A-Z0-9]', '', 'g') = v_zona_cmp
        and btrim(regexp_replace(
              regexp_replace(
                upper(translate(coalesce(x.nombre,''),
                                'ÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇáàäâãéèëêíìïîóòöôõúùüûñç',
                                'AAAAAEEEEIIIIOOOOOUUUUNCAAAAAEEEEIIIIOOOOOUUUUNC')),
                '[^A-Z ]+', '', 'g'),
              ' {2,}', ' ', 'g')) = v_nombre || ' ' || l.letra)
    order by l.ord
    limit 4
  ) c;

  return jsonb_build_object(
    'ok', true,
    'ocupado', true,
    'motivo', 'OCUPADO',
    'nombre', v_nombre,
    'zona', v_zona,
    -- nombre/zona TAL COMO están guardados: es lo que hay que mandarle a mos.pedir_extension
    -- para que reconstruya el MISMO id_dia (upper('Jesús') <> 'JESUS').
    'nombreReal', coalesce(r.nombre, v_nombre),
    'zonaReal', upper(coalesce(r.zona, v_zona)),
    'idDia', r.id_dia,
    'idPersonal', r.id_personal,
    'rol', upper(coalesce(r.rol,'VENDEDOR')),
    'estadoSesion', upper(coalesce(r.estado_sesion,'')),
    'horaIngreso', r.hora_ingreso,
    'horaIngresoTxt', to_char(r.hora_ingreso at time zone 'America/Lima', 'HH24:MI'),
    'ultimaConexionTxt', to_char(r.ultima_conexion at time zone 'America/Lima', 'HH24:MI'),
    'equipos', v_equipos,
    'equiposActivos', v_activos,
    'principalDeviceId', v_ppal,
    'sugerencia', coalesce(v_sug->>0, v_nombre || ' A'),
    'sugerencias', v_sug
  );
end;
$function$;

revoke all on function mos.nombre_zona_ocupado(jsonb) from public;
revoke all on function mos.nombre_zona_ocupado(jsonb) from anon;   -- ME ya tiene token al llegar al wizard
grant execute on function mos.nombre_zona_ocupado(jsonb) to authenticated, service_role;

comment on function mos.nombre_zona_ocupado(jsonb) is
  '734 · ¿ya hay alguien con ese NOMBRE trabajando en esa ZONA hoy y desde OTRO equipo? '
  'Solo informa (el wizard de ME decide). No es conflicto: otra zona, el mismo equipo/extensión, '
  'o un turno del día ya cerrado.';

commit;
