-- 961_wh_despacho_push_zona.sql — PUSH + AUDIO a la zona destino al EMITIR un despacho de almacén
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- Al insertarse una guía SALIDA_ZONA (despacho almacén→zona, incluye pickups GPCK_), avisa EN EL INSTANTE a los
-- operadores (cajeros + vendedores) que tienen caja ABIERTA en esa zona destino: push + audio "tu carga está
-- saliendo del almacén, prepárate". Reusa la infra de push (mos.emitir_push → Edge push, con Urgency:high).
--
-- TARGETING por zona (no existía): me.cajas con estado='ABIERTA' y zona_id=<destino> → dispositivo_id[] (deviceIds)
--   + vendedor[] (usuarios). Es la tabla de "sesión por zona" real (mos.dispositivos no tiene zona).
--
-- ⚠ BEST-EFFORT: TODO el cuerpo va en begin/exception-when-others-then-null → si el push falla (red, vault, sin
--   operadores), el INSERT de la guía SIGUE. NUNCA rompe la emisión del despacho (dinero/inventario intacto).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function wh._trg_despacho_notifica_zona()
returns trigger
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_zona  text := upper(btrim(coalesce(new.id_zona,'')));
  v_devs  jsonb;
  v_users jsonb;
  v_hora  text := to_char(now() at time zone 'America/Lima','HH24:MI');
begin
  begin
    -- solo despachos a una zona REAL (excluye mock/fallback)
    if v_zona = '' or v_zona like '%MOCK%' or v_zona like '%FALLBACK%' then return new; end if;

    -- operadores con caja ABIERTA en la zona destino AHORA (cajeros y vendedores por igual)
    select coalesce(jsonb_agg(distinct d) filter (where d is not null), '[]'::jsonb),
           coalesce(jsonb_agg(distinct u) filter (where u is not null), '[]'::jsonb)
      into v_devs, v_users
      from (
        select nullif(btrim(dispositivo_id),'') d, nullif(btrim(vendedor),'') u
          from me.cajas
         where estado = 'ABIERTA' and upper(btrim(zona_id)) = v_zona
      ) t;

    -- nadie trabajando en esa zona → no hay a quién avisar
    if jsonb_array_length(v_devs) = 0 and jsonb_array_length(v_users) = 0 then return new; end if;

    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('deviceIds', v_devs, 'usuarios', v_users),
      'titulo', '📦 Carga en camino',
      'cuerpo', 'Tu carga está saliendo del almacén. Prepárate para recibirla y contarla.',
      'data', jsonb_build_object(
        'tipo',   'wh_despacho_saliendo',
        'zona',   v_zona,
        'idGuia', new.id_guia,
        'hora',   v_hora)));
  exception when others then
    null;  -- jamás romper la emisión de la guía por un fallo del aviso
  end;
  return new;
end;
$fn$;

drop trigger if exists _trg_despacho_notifica_zona on wh.guias;
create trigger _trg_despacho_notifica_zona
  after insert on wh.guias
  for each row
  when (upper(coalesce(new.tipo,'')) = 'SALIDA_ZONA')
  execute function wh._trg_despacho_notifica_zona();

select 'despacho push zona listo' ok;
