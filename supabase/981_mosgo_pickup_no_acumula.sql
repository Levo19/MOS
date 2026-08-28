-- [981] MosGo F1 (fix) — los pickups MOSGO son ÚNICOS y NO se acumulan por semana.
--  El trigger wh._tg_pickup_consolidar absorbía CUALQUIER pickup nuevo dentro del acumulador semanal de su
--  zona (estado ABSORBIDO → PCK-ACU-<zona>-<semana>). Decisión del dueño: un pedido MosGo es un pickup único
--  e irrepetible, sin reglas de acumulador. Se agrega una guardia para saltar la consolidación cuando el
--  pickup es MOSGO (por fuente o por zona). El resto (pickups de zona) sigue igual.
create or replace function wh._tg_pickup_consolidar()
 returns trigger language plpgsql security definer set search_path to '' as $function$
declare v_bucket date;
begin
  -- [981] MosGo = pickup ÚNICO por pedido → jamás entra al acumulador semanal.
  if upper(coalesce(NEW.fuente,'')) = 'MOSGO' or upper(coalesce(NEW.id_zona,'')) = 'MOSGO' then
    return null;
  end if;
  -- [40x · A] La consolidación NUNCA debe bloquear la creación del pickup. Si algo falla, la subtransacción
  -- del EXCEPTION revierte SOLO la consolidación parcial; el INSERT del pickup persiste y el cron repara.
  v_bucket := wh._bucket_despacho((now() at time zone 'America/Lima')::date);   -- [803] semana vigente
  perform wh.consolidar_pickup_zona(coalesce(NEW.id_zona,''), v_bucket);
  return null;
exception when others then
  return null;
end;
$function$;

select '981 mosgo pickup no acumula listo' as ok;
