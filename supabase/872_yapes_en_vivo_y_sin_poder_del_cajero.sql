-- 872 · Modo Cajero: dos decisiones del dueño (19-ago).
--
-- A) EL CAJERO NO ATA YAPES. Se retira me.yape_atar_cobro (871). El match lo hace el sistema
--    (cron yape-matchear) y verificar / desverificar / soltar es del ADMIN en MOS
--    (mos.yape_resolver). "No quiero que el cajero tenga ese poder."
--
-- B) YAPES EN VIVO. El río de la estación se refrescaba cada 9 s por sondeo. Ahora, cuando un
--    Yape entra o cambia de estado, se toca me.ops_meta (dominio 'yapes'), que YA está en la
--    publicación realtime y que MosExpress YA escucha para el stock de zona. La estación
--    recarga el río en el segundo. Sin exponer la tabla de Yapes por RLS a los dispositivos:
--    ops_meta solo lleva un contador; el detalle sigue viniendo por la RPC yapes_rio (que
--    filtra por zona y no entrega el texto crudo de la notificación).

begin;

drop function if exists me.yape_atar_cobro(jsonb);

create or replace function mos._tg_yape_toca_ops_meta()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  insert into me.ops_meta (dominio, version, updated_at)
       values ('yapes', 1, now())
  on conflict (dominio) do update
     set version = me.ops_meta.version + 1, updated_at = now();
  return null;
end $$;

drop trigger if exists tg_yape_toca_ops_meta on mos.yapes_entrantes;
create trigger tg_yape_toca_ops_meta
  after insert or update of estado, id_venta, monto on mos.yapes_entrantes
  for each row execute function mos._tg_yape_toca_ops_meta();

commit;

-- comprobación: la clave primaria de ops_meta es dominio (el on conflict lo necesita)
select conname from pg_constraint where conrelid = 'me.ops_meta'::regclass;
select dominio, version from me.ops_meta order by dominio;
