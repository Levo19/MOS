-- 136 · Realtime para la lista de pickup: bumpea wh.ops_meta dominio 'pickups' al cambiar
--       wh.pickups → WH se suscribe y refresca la lista al INSTANTE (antes solo poller 30s).
-- FOR EACH STATEMENT (eficiente). No recursivo (solo escribe wh.ops_meta, no wh.pickups).
drop trigger if exists tg_bump_ops_pickups on wh.pickups;
create trigger tg_bump_ops_pickups
after insert or delete or update on wh.pickups
for each statement execute function wh._tg_bump_ops('pickups');
