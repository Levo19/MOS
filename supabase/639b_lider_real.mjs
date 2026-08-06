// 639b · BLINDAJE contra dato sucio hallado en 639: 53 sku_base tienen VARIOS "CANONICO"
// (filas PRE### legacy con nombres basura tipo "TRIPACK"/"1UN" que en realidad eran
// presentaciones). NO se les cambia el tipo aquí (implicancia de stock/ventas — decisión
// del dueño); lo que se blinda es la HERENCIA:
//   1. Elección de líder: gana el que tiene ficha IA; luego el que no es PRE###; luego
//      el de nombre más largo (el real).
//   2. La cascada jamás PISA ficha/categoría de los hijos con NULL (una fila basura sin
//      ficha no puede borrar lo heredado del líder real).
//   3. Re-backfill de presentaciones con el líder real → las 2 PERLA quedan completas.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const FICHA = String.raw`
create or replace function mos._tg_herencia_ficha() returns trigger
language plpgsql security definer set search_path to '' as $fn$
declare v_l record;
begin
  if tg_op = 'INSERT' then
    if new.tipo_producto::text = 'CANONICO' then
      if new.categoria_ia is null then
        new.categoria_ia := coalesce(
          mos.clasificar_producto(new.descripcion, new.descripcion_ia),
          case when nullif(btrim(coalesce(new.id_categoria,'')),'') is not null
               then jsonb_build_object('categoria', new.id_categoria, 'subcategoria', 'Por clasificar') end);
      end if;
    elsif new.tipo_producto::text = 'PRESENTACION' then
      -- líder REAL: con ficha > no-PRE legacy > nombre más largo (hay 53 sku con duplicados sucios)
      select marca, descripcion_ia, categoria_ia into v_l from mos.productos
       where sku_base = new.sku_base and tipo_producto::text in ('CANONICO','DERIVADO')
         and codigo_barra is distinct from new.codigo_barra
       order by (descripcion_ia is not null) desc, (codigo_barra !~* '^PRE[0-9]') desc, length(descripcion) desc
       limit 1;
      if found then
        new.descripcion_ia := coalesce(v_l.descripcion_ia, new.descripcion_ia);
        new.categoria_ia   := coalesce(v_l.categoria_ia,   new.categoria_ia);
        if nullif(btrim(coalesce(v_l.marca,'')),'') is not null then new.marca := v_l.marca; end if;
      end if;
    elsif new.tipo_producto::text = 'DERIVADO' then
      select descripcion_ia, categoria_ia into v_l from mos.productos
       where sku_base = new.codigo_producto_base and tipo_producto::text = 'CANONICO'
       order by (descripcion_ia is not null) desc, (codigo_barra !~* '^PRE[0-9]') desc, length(descripcion) desc
       limit 1;
      if found then
        new.descripcion_ia := coalesce(v_l.descripcion_ia, new.descripcion_ia);
        new.categoria_ia   := coalesce(v_l.categoria_ia,   new.categoria_ia);
      end if;
      new.marca := 'TONYS';
    end if;
  elsif tg_op = 'UPDATE' and new.tipo_producto::text = 'CANONICO'
        and (new.descripcion is distinct from old.descripcion
          or new.codigo_barra is distinct from old.codigo_barra) then
    new.categoria_ia := coalesce(mos.clasificar_producto(new.descripcion, new.descripcion_ia), new.categoria_ia);
    new.ia_refresh := true;
  end if;
  return new;
end $fn$;`;

const CASCADA = String.raw`
create or replace function mos._tg_herencia_cascada() returns trigger
language plpgsql security definer set search_path to '' as $fn$
begin
  if pg_trigger_depth() > 4 then return null; end if;
  -- coalesce: un líder SIN ficha (p.ej. fila basura PRE legacy) nunca borra lo heredado
  if new.tipo_producto::text = 'CANONICO' then
    update mos.productos d
       set descripcion_ia = coalesce(new.descripcion_ia, d.descripcion_ia),
           categoria_ia   = coalesce(new.categoria_ia,   d.categoria_ia),
           marca = 'TONYS'
     where d.tipo_producto::text = 'DERIVADO' and d.codigo_producto_base = new.sku_base
       and (coalesce(new.descripcion_ia, d.descripcion_ia) is distinct from d.descripcion_ia
         or coalesce(new.categoria_ia, d.categoria_ia) is distinct from d.categoria_ia
         or coalesce(d.marca,'') <> 'TONYS');
    update mos.productos pr
       set descripcion_ia = coalesce(new.descripcion_ia, pr.descripcion_ia),
           categoria_ia   = coalesce(new.categoria_ia,   pr.categoria_ia),
           marca = case when nullif(btrim(coalesce(new.marca,'')),'') is not null then new.marca else pr.marca end
     where pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = new.sku_base
       and (coalesce(new.descripcion_ia, pr.descripcion_ia) is distinct from pr.descripcion_ia
         or coalesce(new.categoria_ia, pr.categoria_ia) is distinct from pr.categoria_ia
         or (nullif(btrim(coalesce(new.marca,'')),'') is not null and pr.marca is distinct from new.marca));
  elsif new.tipo_producto::text = 'DERIVADO' then
    update mos.productos pr
       set descripcion_ia = coalesce(new.descripcion_ia, pr.descripcion_ia),
           categoria_ia   = coalesce(new.categoria_ia,   pr.categoria_ia),
           marca = 'TONYS'
     where pr.tipo_producto::text = 'PRESENTACION' and pr.sku_base = new.sku_base
       and (coalesce(new.descripcion_ia, pr.descripcion_ia) is distinct from pr.descripcion_ia
         or coalesce(new.categoria_ia, pr.categoria_ia) is distinct from pr.categoria_ia
         or coalesce(pr.marca,'') <> 'TONYS');
  end if;
  return null;
end $fn$;`;

// re-backfill de presentaciones con LÍDER REAL (lateral con la misma elección del trigger)
const REBACK = String.raw`
update mos.productos pr
   set descripcion_ia = coalesce(l.descripcion_ia, pr.descripcion_ia),
       categoria_ia   = coalesce(l.categoria_ia,   pr.categoria_ia),
       marca = case when nullif(btrim(coalesce(l.marca,'')),'') is not null then l.marca else pr.marca end
  from (
    select distinct on (x.sku_base) x.sku_base, x.marca, x.descripcion_ia, x.categoria_ia
      from mos.productos x
     where x.tipo_producto::text in ('CANONICO','DERIVADO')
     order by x.sku_base, (x.descripcion_ia is not null) desc, (x.codigo_barra !~* '^PRE[0-9]') desc, length(x.descripcion) desc
  ) l
 where pr.tipo_producto::text = 'PRESENTACION' and l.sku_base = pr.sku_base
   and (pr.categoria_ia is null or pr.descripcion_ia is null)`;

const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };

await c.query('begin');
await c.query(FICHA); await c.query(CASCADA);

// test 1: insertar presentación bajo LEV553 (sku sucio con canónico basura "BOLSA") → hereda de PERLA IMPORTADA
await c.query(`insert into mos.productos (id_producto, sku_base, codigo_barra, descripcion, tipo_producto, estado, precio_venta, factor_conversion, fecha_creacion)
  values ('IDT639B1','LEV553','TEST639B1','PERLA TEST · 3 un','PRESENTACION',true,10,3,now())`);
{
  const r = (await c.query(`select descripcion_ia is not null f, categoria_ia from mos.productos where codigo_barra='TEST639B1'`)).rows[0];
  chk('en sku sucio la presentación hereda del líder REAL', r.f === true && r.categoria_ia != null, JSON.stringify(r.categoria_ia));
}
// test 2: update de la fila basura (PRE209 «BOLSA», sin ficha) NO borra la ficha de los hijos
await c.query(`update mos.productos set marca='X639' where codigo_barra='PRE209'`);
{
  const r = (await c.query(`select descripcion_ia is not null f, categoria_ia is not null cta from mos.productos where codigo_barra='TEST639B1'`)).rows[0];
  chk('fila basura no pisa la herencia con NULL', r.f === true && r.cta === true, JSON.stringify(r));
}
// test 3: re-backfill deja 0 presentaciones sin categoría
const rb = await c.query(REBACK);
{
  const v = (await c.query(`select count(*) n from mos.productos where tipo_producto::text='PRESENTACION' and coalesce(estado,true) and categoria_ia is null`)).rows[0];
  chk('re-backfill: 0 presentaciones activas sin categoría', Number(v.n) === 0, `arregladas=${rb.rowCount} quedan=${v.n}`);
}
t.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 120) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} — NO se aplica`); await c.end(); process.exit(1); }

await c.query('begin');
await c.query(FICHA); await c.query(CASCADA);
const rr = await c.query(REBACK);
const v = (await c.query(`select
  (select count(*) from mos.productos where tipo_producto::text='PRESENTACION' and coalesce(estado,true) and categoria_ia is null) sin_cat,
  (select count(*) from mos.productos where tipo_producto::text='PRESENTACION' and coalesce(estado,true)) tot`)).rows[0];
if (Number(v.sin_cat) > 0) { console.log('❌ aún quedan sin categoría — ROLLBACK'); await c.query('rollback'); await c.end(); process.exit(1); }
await c.query('commit');
fs.writeFileSync('639_taxonomia_herencia.sql', FICHA + '\n\n' + CASCADA + '\n\n-- re-backfill presentaciones líder real:\n-- ' + REBACK.replace(/\n/g, '\n-- '));
console.log(`\n✅ 639b aplicado · presentaciones re-heredadas=${rr.rowCount} · sin categoría=${v.sin_cat}/${v.tot}`);
await c.end();
