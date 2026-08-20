-- [887] MESA DE COMPRAS EN TIEMPO REAL — cerrar el último flanco.
-- La Mesa (modal en MOS) se alimenta de: wh.guias (proveedor/cabecera/estado) → bump 'guias' OK;
-- cantidades de zona vía me.editar_guia_lineas → bump 'stock_zonas' OK. Lo único sin cubrir era la
-- CABECERA de una guía de ZONA (me.guias_cabecera: observación / zona_destino), que no tenía trigger
-- de bump → editarla no despertaba a nadie. Le colgamos el MISMO trigger statement-level de 203
-- (no toca la fila fuente; solo sube un contador en me.ops_meta), reusando el dominio 'stock_zonas'
-- que el front ya rutea hacia la Mesa. Idempotente.

drop trigger if exists tg_bump_ops_guias_cab on me.guias_cabecera;
create trigger tg_bump_ops_guias_cab
  after insert or update or delete on me.guias_cabecera
  for each statement execute function me._tg_bump_ops('stock_zonas');

-- verificación
select 'trigger creado' as ok, tgname
  from pg_trigger where tgrelid='me.guias_cabecera'::regclass and tgname='tg_bump_ops_guias_cab';
