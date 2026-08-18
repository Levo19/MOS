-- 846_base_diaria_por_zona.sql
--
-- [DUEÑO] "quiero poder setear la base diaria de las zonas... porque sé que actualmente jala de una
--  tabla como un usuario genérico. Quiero que elimines eso. En Zona 1 y Zona 2, al lado de las metas,
--  un chip de BASE CAJERO y BASE VENDEDOR para yo setear, y al cambiarlo se recalcula desde hoy."
--
-- EL PROBLEMA REAL (medido antes de tocar nada):
--   mos._fijo_personal(id, rol) resolvía el sueldo base en cascada y su 2ª rama era
--     "el monto_base MÁS ALTO de CUALQUIER otra persona activa con el mismo rol"
--   es decir: el sueldo de una persona salía del registro de OTRA. Ese es el "usuario genérico".
--   Los 32 cajeros/vendedores de ZONA-01 y ZONA-02 son en su mayoría temporales de ME sin fila en
--   mos.personal, así que TODOS cobraban S/50 por esa rama o por el default global evalFijoCajero /
--   evalFijoVendedor — un solo número para las dos zonas, sin forma de distinguirlas.
--
-- LA SOLUCIÓN — NO se crea infraestructura nueva. Se REDIRIGE a la que ya existe:
--   la política de zona versionada (mos.zonas.politica_json + mos.zona_politica_historial), la misma
--   que ya gobierna metaDiaria y comisionExcedentePct, con su vigencia por día y su recálculo
--   automático de las liquidaciones PENDIENTES (SQL 509/730/731). Solo se agregan dos campos:
--     baseCajero · baseVendedor
--   Con eso, gratis y sin código nuevo: vigencia por fecha, no retroactividad, historial auditable
--   y "si hoy lo muevo, hoy se recalcula" (actualizar_zona ya recorre los días PENDIENTES).
--
-- NEUTRALIDAD VERIFICADA: hoy los 32 cajeros/vendedores reciben S/50 y ninguno tiene monto_base
-- propio; se siembra la política de ambas zonas en 50, así que el día de la migración nadie cambia
-- de sueldo y ningún día viejo se mueve.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) La base diaria que la ZONA paga a un rol un día dado.
--    Cascada honesta: historial vigente ese día → política actual de la zona → default global.
--    Devuelve NULL para roles que no son de zona (almacenero, envasador…) o si no hay zona:
--    esos siguen resolviéndose por su propia base, como siempre.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos._base_zona(p_zona text, p_rol text, p_dia date)
returns numeric language plpgsql stable security definer set search_path to '' as $fn$
declare v_campo text; v_val numeric; v_dia date;
begin
  v_campo := case upper(btrim(coalesce(p_rol,'')))
               when 'CAJERO'   then 'baseCajero'
               when 'VENDEDOR' then 'baseVendedor'
               else null end;
  if v_campo is null or btrim(coalesce(p_zona,'')) = '' then return null; end if;
  v_dia := coalesce(p_dia, (now() at time zone 'America/Lima')::date);

  -- 1) el valor que regía ESE día (historial versionado)
  v_val := mos._politica_valor(p_zona, v_campo, v_dia);
  if v_val is not null then return v_val; end if;
  -- 2) la política actual de la zona (aún sin historial: nunca se cambió)
  select mos._numn(politica_json->>v_campo) into v_val
    from mos.zonas where upper(btrim(id_zona)) = upper(btrim(p_zona)) limit 1;
  if v_val is not null then return v_val; end if;
  -- 3) el default global por rol (evalFijoCajero / evalFijoVendedor)
  select mos._numn(valor) into v_val
    from mos.config where clave = 'evalFijo' || initcap(lower(btrim(coalesce(p_rol,'')))) limit 1;
  return v_val;
end $fn$;

grant execute on function mos._base_zona(text,text,date) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) El sueldo base de una persona, ahora consciente de ZONA y DÍA.
--    Para roles de zona manda la ZONA: es la única palanca, la que el dueño mueve desde Config y
--    la que puede distinguir Zona 01 de Zona 02 (mos.personal ni siquiera tiene columna de zona).
--    Para los demás roles sigue mandando su propia base, exactamente como hasta hoy.
--    MUERE la rama del "usuario genérico": el sueldo de alguien nunca más sale del registro de otro.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mos._fijo_personal(p_id_personal text, p_rol text, p_zona text, p_dia date)
returns numeric language plpgsql stable security definer set search_path to '' as $fn$
declare v numeric;
begin
  -- 1) política de la zona (cajero / vendedor), con la vigencia de ese día
  v := mos._base_zona(p_zona, p_rol, p_dia);
  if v is not null then return v; end if;
  -- 2) la base propia de la persona (almacenero, envasador, y cualquiera fuera de zona)
  select monto_base into v from mos.personal
   where id_personal = p_id_personal and monto_base is not null limit 1;
  if v is not null then return v; end if;
  -- 3) default global por rol
  select mos._numn(valor) into v from mos.config
   where clave = 'evalFijo' || initcap(lower(btrim(coalesce(p_rol,'')))) limit 1;
  return coalesce(v, 0::numeric);
end $fn$;

grant execute on function mos._fijo_personal(text,text,text,date) to anon, authenticated, service_role;

-- la firma vieja queda como envoltura: mismo nombre, cero rama genérica. Nada que la llame se rompe.
create or replace function mos._fijo_personal(p_id_personal text, p_rol text)
returns numeric language sql stable security definer set search_path to '' as $fn$
  select mos._fijo_personal(p_id_personal, p_rol, null::text, null::date);
$fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) Semilla del historial para los dos campos nuevos, dentro del registrador que ya existe.
--    La 1ª vez que el dueño cambie una base, el valor ANTERIOR queda sellado desde '2000-01-01'
--    → ningún día viejo hereda el valor nuevo.
-- ─────────────────────────────────────────────────────────────────────────────
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = '_zona_politica_registrar';

  v_new := replace(v_def,
    $old$                when 'metaDiaria'           then mos._numn((select valor from mos.config where clave='evalMetaCajero' limit 1))$old$,
    $new$                when 'metaDiaria'           then mos._numn((select valor from mos.config where clave='evalMetaCajero' limit 1))
                when 'baseCajero'          then mos._numn((select valor from mos.config where clave='evalFijoCajero' limit 1))
                when 'baseVendedor'        then mos._numn((select valor from mos.config where clave='evalFijoVendedor' limit 1))$new$);

  if v_new = v_def then raise exception '846: no se encontró el case de semillas en _zona_politica_registrar'; end if;
  execute v_new;
end $mig$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) actualizar_zona versiona los dos campos nuevos igual que meta y comisión.
--    Con esto hereda gratis el recálculo de las liquidaciones PENDIENTES desde la vigencia (731):
--    cambiar la base hoy recalcula el día de hoy.
-- ─────────────────────────────────────────────────────────────────────────────
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'actualizar_zona';

  v_new := replace(v_def,
    $old$    perform mos._zona_politica_registrar(v_id, 'metaDiaria',           mos._numn(v_pol->>'metaDiaria'),           v_vig, v_por);$old$,
    $new$    perform mos._zona_politica_registrar(v_id, 'metaDiaria',           mos._numn(v_pol->>'metaDiaria'),           v_vig, v_por);
    -- [846] la base diaria por rol vive en la MISMA política versionada
    perform mos._zona_politica_registrar(v_id, 'baseCajero',           mos._numn(v_pol->>'baseCajero'),           v_vig, v_por);
    perform mos._zona_politica_registrar(v_id, 'baseVendedor',         mos._numn(v_pol->>'baseVendedor'),         v_vig, v_por);$new$);

  if v_new = v_def then raise exception '846: no se encontró el registro de metaDiaria en actualizar_zona'; end if;
  execute v_new;
end $mig$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) Los dos consumidores del sueldo base pasan a la firma con zona y día.
-- ─────────────────────────────────────────────────────────────────────────────
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'recomputar_dia';
  -- v_zona y v_dia ya están resueltos arriba de esta línea
  v_new := replace(v_def,
    $old$  v_fijo    := mos._fijo_personal(v_idp, v_rol);$old$,
    $new$  v_fijo    := mos._fijo_personal(v_idp, v_rol, v_zona, v_dia);   -- [846] base de la zona, vigente ese día$new$);
  if v_new = v_def then raise exception '846: no se encontró la llamada a _fijo_personal en recomputar_dia'; end if;
  execute v_new;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'registrar_ingreso_personal';
  v_new := replace(v_def,
    $old$  v_fijo    := mos._fijo_personal(v_idp, v_rol);$old$,
    $new$  v_fijo    := mos._fijo_personal(v_idp, v_rol, v_zona, (now() at time zone 'America/Lima')::date);   -- [846]$new$);
  if v_new = v_def then raise exception '846: no se encontró la llamada a _fijo_personal en registrar_ingreso_personal'; end if;
  execute v_new;
end $mig$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6) Semilla de datos: la política de cada zona de venta arranca con la base que HOY rige de
--    verdad (el default global), para que el chip diga la verdad desde el primer momento y para
--    que ni hoy ni ningún día anterior cambie de monto.
-- ─────────────────────────────────────────────────────────────────────────────
update mos.zonas z
   set politica_json = coalesce(z.politica_json, '{}'::jsonb)
       || jsonb_build_object(
            'baseCajero',   coalesce(mos._numn((select valor from mos.config where clave='evalFijoCajero'   limit 1)), 0),
            'baseVendedor', coalesce(mos._numn((select valor from mos.config where clave='evalFijoVendedor' limit 1)), 0))
 where jsonb_typeof(coalesce(z.politica_json,'{}'::jsonb)) = 'object'
   and not (coalesce(z.politica_json,'{}'::jsonb) ? 'baseCajero')
   and exists (select 1 from mos.liquidaciones_dia l
                where upper(btrim(coalesce(l.zona,''))) = upper(btrim(z.id_zona))
                  and upper(coalesce(l.rol,'')) in ('CAJERO','VENDEDOR'));

commit;
