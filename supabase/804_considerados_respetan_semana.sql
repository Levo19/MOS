-- 804_considerados_respetan_semana.sql — [DUEÑO] "revisá que la lista de considerados también
-- respete el acumulado hasta el domingo: es una lista donde matchea producto que ingresa con
-- producto que deben y NO aparece en el acumulado semanal".
--
-- Con el 803 el trigger ya pregunta por la semana correcta (`_bucket_despacho(hoy)`), así que hoy
-- domingo mira el acumulador `PCK-ACU-%-2026-08-09`, que es el vivo. ANTES del 803 miraba
-- `...-2026-08-16` —que no existe— y por lo tanto **todo lo que se debe esta semana habría entrado
-- como "considerado" en vez de "priorizado"**. Eso ya quedó bien.
--
-- PERO la frontera nueva abre una ventana que antes no existía: la venta del DOMINGO ya no se
-- absorbe ese mismo día (siembra el acumulador del lunes). Entre el cierre de caja del domingo y
-- la consolidación del lunes hay un pickup VIVO que todavía no está dentro de ningún acumulador.
-- Con la pregunta escrita como estaba —"¿existe deuda en el acumulador de ESTA semana?"— un
-- ingreso en esa ventana marcaría como CONSIDERADO algo que en realidad ya está en cola para
-- despacharse mañana. Sería mandarle al operador "considerá enviar esto" cuando ya lo tiene
-- pedido: exactamente el ruido que el dueño quiso evitar con la distinción considerado/priorizado.
--
-- FIX: la pregunta "¿se debe AHORA?" pasa a mirar CUALQUIER pickup en estado vivo
-- (PENDIENTE / EN_PROCESO / PARCIAL) — que incluye al acumulador de la semana y a los pickups
-- fuente aún no absorbidos. Es la lectura operativa de "aparece en el acumulado": si está pedido
-- y todavía no se despachó, es PRIORIZADO, no considerado.
--
-- El lado de los rezagados NO cambia y sigue respetando el corte: solo acumuladores REZAGADO con
-- clave en [semana_vigente − 28 días, semana_vigente), o sea las 4 semanas CERRADAS anteriores.
-- Como las claves se anclan al domingo que abre la semana, "hasta el domingo" queda respetado:
-- la semana en curso nunca entra en la ventana de rezagados.

create or replace function wh._mig804_patch(p_fn text, p_old text, p_new text, p_veces int)
returns void language plpgsql as $$
declare v_def text; v_new text; v_oid oid; v_n int;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'wh' and p.proname = p_fn order by p.oid limit 1;
  if v_oid is null then raise exception '[804] wh.% no existe', p_fn; end if;
  v_def := pg_get_functiondef(v_oid);
  v_n := (length(v_def) - length(replace(v_def, p_old, ''))) / nullif(length(p_old), 0);
  if v_n <> p_veces then
    raise exception '[804] wh.%: se esperaban % ocurrencias y hay %', p_fn, p_veces, v_n;
  end if;
  v_new := replace(v_def, p_old, p_new);
  execute v_new;
end $$;

-- ── (1) "¿se debe AHORA?" = deuda en cualquier pickup VIVO, no solo en el acumulador por clave ──
select wh._mig804_patch('tg_considerado_ingreso',
$old$    select exists (
      select 1 from wh.pickups pk
      cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
      where pk.fuente = 'ACUMULADO_SEMANAL'
        and pk.id_pickup like 'PCK-ACU-%-' || v_bstr
        and it->>'skuBase' = v_sku
        and wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0')) > 0
    ) into v_hoy;$old$,
$new$    -- [804] PRIORIZADO = se debe AHORA. Mira todo lo VIVO: el acumulador de la semana y
    -- también los pickups fuente que todavía no fueron absorbidos (p.ej. la venta del domingo,
    -- que desde el 803 recién se consolida el lunes). Si está pedido y sin despachar, ya está
    -- en cola: avisar "considerá enviarlo" sería ruido.
    select exists (
      select 1 from wh.pickups pk
      cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
      where upper(coalesce(pk.estado,'')) in ('PENDIENTE','EN_PROCESO','PARCIAL')
        and it->>'skuBase' = v_sku
        and wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0')) > 0
    ) into v_hoy;$new$, 1);

-- ── (2) la ventana de rezagados: dejar EXPLÍCITO que son las 4 semanas CERRADAS ──
-- (mismo comportamiento, comentario para que nadie la mueva sin entender el corte)
select wh._mig804_patch('tg_considerado_ingreso',
$old$           and to_date(right(pk.id_pickup,10),'YYYY-MM-DD') >= v_bucket - 28$old$,
$new$           -- [804] 4 semanas CERRADAS: desde v_bucket-28 hasta ANTES de la semana vigente.
           -- La semana en curso jamás entra acá — para eso está el chequeo de PRIORIZADO.
           and to_date(right(pk.id_pickup,10),'YYYY-MM-DD') >= v_bucket - 28$new$, 1);

drop function wh._mig804_patch(text,text,text,int);

-- ── (3) `considerados_listar` escribía SIEMPRE en el camino de lectura ──
-- El UPDATE de vencidos corría en cada listado (y el listado se pollea cada 60s desde MOS):
-- toma lock de fila y hace la lectura no idempotente. Ahora solo escribe si hay algo que vencer.
-- Mismo criterio que se aplicó a `membrete_cola_listar` en el 795.
create or replace function wh.considerados_listar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_items jsonb;
  v_lim   int := greatest(1, least(200, coalesce((p->>'limite')::int, 50)));
begin
  if exists (select 1 from wh.considerados
              where estado = 'ACTIVO' and creado < now() - interval '7 days') then
    update wh.considerados set estado = 'VENCIDO'
     where estado = 'ACTIVO' and creado < now() - interval '7 days';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', z.id, 'skuBase', z.sku_base, 'nombre', z.nombre,
           'cant', z.cant_ingresada, 'zonas', z.zonas, 'guiaTipo', z.guia_tipo,
           'idGuia', z.id_guia,
           'creado', to_char(z.creado at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI')
         ) order by z.creado desc), '[]'::jsonb)
    into v_items
    from (select * from wh.considerados where estado = 'ACTIVO' order by creado desc limit v_lim) z;

  return jsonb_build_object('ok', true, 'items', v_items,
    'total', (select count(*) from wh.considerados where estado = 'ACTIVO'));
end;
$function$;

grant execute on function wh.considerados_listar(jsonb) to anon, authenticated, service_role;
