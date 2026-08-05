import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='wh' and p.proname='cerrar_lista_sombra' and p.prokind='f'`)).rows[0].d;
fs.writeFileSync('_def_cerrar_sombra.sql', d);
console.log('líneas:', d.split('\n').length);
console.log('── bloques exception:');
d.split('\n').forEach((l, i) => { if (/exception|when others|PCK-LSC|insert into wh\.pickups|return jsonb/i.test(l)) console.log('  ' + (i+1) + ': ' + l.trim().slice(0, 120)); });
console.log('\n── ¿cuántas sombras COMPLETADA tienen su acumulado PCK-LSC?');
console.table((await c.query(`
  select count(*) completadas,
         count(*) filter (where exists (select 1 from wh.pickups pk where pk.id_pickup = 'PCK-LSC-'||ls.id_lista)) con_acumulado
    from wh.listas_sombra ls where upper(coalesce(ls.estado,''))='COMPLETADA'`)).rows);
await c.end();
