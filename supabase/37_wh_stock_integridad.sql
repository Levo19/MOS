-- 37_wh_stock_integridad.sql — Regla: UNA fila por producto en wh.stock (cod_producto).
-- 1) Consolida duplicados existentes: conserva la de ultima_actualizacion MÁS RECIENTE (la vigente), borra las otras.
-- 2) Índice ÚNICO en cod_producto → previene futuros duplicados (un INSERT duplicado fallará y el reintento hará UPDATE).

-- 1) borrar las filas que NO son la más reciente por producto
delete from wh.stock a
 using wh.stock b
 where a.cod_producto = b.cod_producto
   and a.id_stock <> b.id_stock
   and ( a.ultima_actualizacion < b.ultima_actualizacion
      or (a.ultima_actualizacion = b.ultima_actualizacion and a.id_stock < b.id_stock) );

-- 2) índice único (idempotente)
create unique index if not exists ux_wh_stock_cod on wh.stock (cod_producto);
