-- 808_nombre_puesto_por_persona.sql — la condición "el dispositivo debe tener un nombre", bien.
--
-- El 807 exigía nombre propio rechazando el patrón autogenerado. Al probarlo contra los datos
-- reales salió que hay CUATRO familias de nombre automático conviviendo, no una:
--     "PC 963c64"                    ← mos._label_plataforma (el trigger de autolabel)
--     "Windows · Chrome (3f8b6a)"    ← lo manda el navegador al registrarse
--     "Desktop MOS 08:12"            ← idem, con la hora
--     "Dispositivo 0b587831" / ""    ← registros viejos y 53 equipos sin nombre
-- Una lista negra que persiga esos cuatro patrones es frágil: mañana el front inventa un quinto
-- y un equipo sin bautizar pasa el filtro. Se da vuelta la pregunta: en vez de adivinar si el
-- nombre es automático, se REGISTRA cuándo lo puso una persona.
--
--   `mos.dispositivos.nombre_manual` = true solo cuando el nombre se cambió desde el panel
--   (`mos.admin_actualizar_dispositivo`, que es el botón ✏️ Editar de Infraestructura).
--
-- Además se tapa una fuga que ya existía: `mos.actualizar_dispositivo` —la que llama el PROPIO
-- equipo en cada sesión— pisaba `nombre_equipo` con lo que mandara el navegador. O sea que el
-- nombre que el dueño escribía a mano ("Jefa · oficina") volvía solo a "Android · Chrome (…)"
-- en la siguiente conexión. Ahora el equipo solo puede nombrarse si nadie lo bautizó antes.

alter table mos.dispositivos add column if not exists nombre_manual boolean not null default false;

comment on column mos.dispositivos.nombre_manual is
  '[808] true = el nombre lo puso una PERSONA desde el panel. Requisito para poder FIJAR el equipo, y blindaje para que el propio equipo no lo pise al reconectarse.';

create or replace function mos._mig808_patch(p_fn text, p_old text, p_new text, p_veces int)
returns void language plpgsql as $$
declare v_def text; v_new text; v_oid oid; v_n int;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = p_fn order by p.oid limit 1;
  if v_oid is null then raise exception '[808] mos.% no existe', p_fn; end if;
  v_def := pg_get_functiondef(v_oid);
  v_n := (length(v_def) - length(replace(v_def, p_old, ''))) / nullif(length(p_old), 0);
  if v_n <> p_veces then
    raise exception '[808] mos.%: se esperaban % ocurrencias y hay %', p_fn, p_veces, v_n;
  end if;
  execute replace(v_def, p_old, p_new);
end $$;

-- (1) El panel bautiza: deja constancia de que el nombre lo puso alguien.
select mos._mig808_patch('admin_actualizar_dispositivo',
  'nombre_equipo   = case when p ? ''Nombre_Equipo''   then coalesce(p->>''Nombre_Equipo'', nombre_equipo)   else nombre_equipo',
  'nombre_manual   = case when p ? ''Nombre_Equipo'' and coalesce(btrim(p->>''Nombre_Equipo''),'''') <> '''' then true else nombre_manual end,   -- [808]
      nombre_equipo   = case when p ? ''Nombre_Equipo''   then coalesce(p->>''Nombre_Equipo'', nombre_equipo)   else nombre_equipo', 1);

-- (2) El equipo ya no pisa el nombre que puso una persona.
select mos._mig808_patch('actualizar_dispositivo',
  'nombre_equipo = coalesce(nullif(btrim(coalesce(p->>''nombreEquipo'','''')),''''), nombre_equipo),',
  'nombre_equipo = case when nombre_manual then nombre_equipo   -- [808] bautizado a mano: intocable
                        else coalesce(nullif(btrim(coalesce(p->>''nombreEquipo'','''')),''''), nombre_equipo) end,', 1);

-- (3) Fijar exige el bautizo, no un patrón adivinado.
select mos._mig808_patch('dispositivo_fijar',
$old$    if coalesce(nullif(btrim(v_d.nombre_equipo),''),'') = ''
       or v_d.nombre_equipo ~* '^(Mobile|Equipo|Móvil|Movil|Tablet|PC|Mac|iPhone|iPad) [0-9a-fA-F]{6}$' then
      return jsonb_build_object('ok',false,'error','SIN_NOMBRE',
        'mensaje','Ponle primero un nombre al equipo (el automático no sirve: hay que saber de quién es).');
    end if;$old$,
$new$    -- [808] no vale el nombre que se puso solo: tiene que haberlo bautizado una persona
    -- desde el panel (botón ✏️ Editar), que es lo que marca `nombre_manual`.
    if not coalesce(v_d.nombre_manual, false) or coalesce(nullif(btrim(v_d.nombre_equipo),''),'') = '' then
      return jsonb_build_object('ok',false,'error','SIN_NOMBRE',
        'mensaje','Primero ponle un nombre al equipo con ✏️ Editar. El que trae puesto es automático y no dice de quién es.');
    end if;$new$, 1);

drop function mos._mig808_patch(text,text,text,int);

-- (4) El panel necesita saberlo para habilitar o no el botón.
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'listar_dispositivos' order by p.oid limit 1;
  if position($anc$'Fijado',                    (d.fijado_ts is not null),$anc$ in v_def) = 0 then
    raise exception '[808] no se encontró el ancla del 807 en listar_dispositivos';
  end if;
  execute replace(v_def,
    $anc$'Fijado',                    (d.fijado_ts is not null),$anc$,
    $anc2$'Fijado',                    (d.fijado_ts is not null),
      'Nombre_Manual',             coalesce(d.nombre_manual,false),$anc2$);
end $$;
