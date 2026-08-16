-- 805_costo_vigente_es_el_ultimo_que_llego.sql
--
-- [DUEÑO, textual] «El costo que se maneja hoy es el del último que llegó, registrado o no. El
-- último en llegar fue el 12 de agosto, así que debería jalar ese punto. Si el 12 de agosto no
-- tuviera registro, toma la fecha anterior. Así de simple, hasta que el admin ponga el costo de
-- hoy. Entonces ¿qué está pasando? ¿Es un tema de lógica o de qué tipo?»
--
-- ES UN TEMA DE LÓGICA, y está en la ESCRITURA, no en el gráfico.
--
-- EVIDENCIA (AJINOMOTO GLUTAMATO 1KG · LEV009, medido hoy):
--   catálogo:            costo vigente S/712.80  ·  precio S/14.50  →  margen −4816%
--   último costo VÁLIDO: S/13.20, guía del 12-ago-2026
--   las 4 escrituras más recientes, ordenadas por CUÁNDO se aplicaron:
--     16-ago 05:06 → S/13.20    (guía del 12-AGO)   ← correcta
--     16-ago 05:09 → S/604.10   (guía del 16-JUL)
--     16-ago 05:11 → S/712.80   (guía del 16-JUL)
--     16-ago 05:12 → S/712.80   (guía del 16-JUL)   ← esta quedó como "costo de hoy"
--
-- O sea: alguien reabrió en Compras una guía de JULIO y, al re-aplicarla, `aplicar_costos_compra`
-- pisó el costo vigente —que venía de una guía de AGOSTO— con el número de julio. La fila del
-- historial quedó bien fechada (16-jul), pero el campo `mos.productos.precio_costo` no tiene
-- fecha: es uno solo, y el último que escribe gana, aunque venga de una guía más vieja.
-- Por eso el gráfico muestra un punto "hoy" en S/712.80 aunque HOY no ingresó nada: ese punto no
-- sale del historial, sale del campo del catálogo.
--
-- (Y de paso, por qué 712.80: la guía de julio tiene **cantidad 1** en sus tres líneas, así que
--  el monto total de la línea se guardó como costo unitario. 54 × 13.20 = 712.80 es exactamente
--  el total de la línea del 12-ago. Mismo número, dos significados.)
--
-- FIX — la regla del dueño, escrita en la función:
--   `precio_costo` solo se pisa si la guía que se está aplicando es **igual o más nueva** que la
--   que produjo el costo vigente. Una guía vieja sigue registrando su historia (con su fecha
--   real, para el gráfico y la auditoría) pero YA NO cambia el costo de hoy.
--   Si no hay historia previa válida, se aplica normal (primer costo del producto).
--   Un costo puesto a mano por el admin desde el catálogo va por otro camino y sigue mandando.

create or replace function mos._mig805_patch(p_fn text, p_old text, p_new text, p_veces int)
returns void language plpgsql as $$
declare v_def text; v_new text; v_oid oid; v_n int;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = p_fn order by p.oid limit 1;
  if v_oid is null then raise exception '[805] mos.% no existe', p_fn; end if;
  v_def := pg_get_functiondef(v_oid);
  v_n := (length(v_def) - length(replace(v_def, p_old, ''))) / nullif(length(p_old), 0);
  if v_n <> p_veces then
    raise exception '[805] mos.%: se esperaban % ocurrencias y hay %', p_fn, p_veces, v_n;
  end if;
  v_new := replace(v_def, p_old, p_new);
  execute v_new;
end $$;

-- (1) variable nueva
select mos._mig805_patch('aplicar_costos_compra',
  '  v_hist jsonb;',
  '  v_hist jsonb;
  v_ult_ts timestamptz;   -- [805] fecha de la guía que produjo el costo vigente', 1);

-- (2) el UPDATE deja de pisar a ciegas
select mos._mig805_patch('aplicar_costos_compra',
$old$    update mos.productos
       set precio_costo = v_costo_canon,$old$,
$new$    -- [805] ¿de qué fecha viene el costo vigente? = la fila de costo VÁLIDA más reciente
    -- del grupo. Si la guía que estamos aplicando es más VIEJA que esa, registramos su
    -- historia pero NO tocamos el costo de hoy: el costo de hoy es el del último que llegó.
    select max(h.ts) into v_ult_ts
      from mos.historial_precio_costo h
     where h.tipo = 'COSTO'
       and h.sku_base = coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto)
       and coalesce(h.id_guia,'') <> coalesce(v_guia,'')
       and mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source,
                                coalesce(v_canon.precio_venta,0), coalesce(v_canon.precio_costo,0)) is null;

    update mos.productos
       set precio_costo = case
             when v_ult_ts is null or v_guia_fecha >= v_ult_ts then v_costo_canon
             else precio_costo   -- guía más vieja que el costo vigente: no lo pisa
           end,$new$, 1);

drop function mos._mig805_patch(text,text,text,int);

-- ── REPARACIÓN: devolver el costo vigente al último que llegó de verdad ──
-- Solo se tocan los canónicos cuyo costo vigente es INSANO (>= precio de venta, la firma del
-- monto de bulto) y que tienen un costo válido anterior al cual volver. Nada más se mueve.
with canon as (
  select pr.id_producto,
         coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) as grp,
         pr.precio_venta, pr.precio_costo
    from mos.productos pr
   where coalesce(nullif(pr.factor_conversion,0),1) = 1
     and coalesce(pr.precio_venta,0) > 0
     and coalesce(pr.precio_costo,0) >= pr.precio_venta
),
ultimo as (
  select c.id_producto, c.grp, c.precio_costo as costo_malo,
         (select h.valor
            from mos.historial_precio_costo h
           where h.tipo = 'COSTO' and h.sku_base = c.grp and h.valor > 0
             and h.valor < c.precio_venta
             and mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source,
                                      c.precio_venta, 0) is null
           order by h.ts desc, h.id desc limit 1) as costo_bueno
    from canon c
)
update mos.productos pr
   set precio_costo = u.costo_bueno
  from ultimo u
 where pr.id_producto = u.id_producto
   and u.costo_bueno is not null;
