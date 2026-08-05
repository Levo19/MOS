// ¿"1 de 33" es un bug o simplemente que el acumulado [540] es nuevo?
// Comparamos contra la fecha en que la función quedó con el bloque del acumulado.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

console.log('── sombras COMPLETADA por fecha de CIERRE vs acumulado creado');
console.table((await c.query(`
  select to_char(coalesce(ls.fecha_completada, ls.fecha_creacion) at time zone 'America/Lima','YYYY-MM-DD') dia_cierre,
         count(*) sombras,
         count(*) filter (where exists (select 1 from wh.pickups pk where pk.id_pickup='PCK-LSC-'||ls.id_lista)) con_acum
    from wh.listas_sombra ls
   where upper(coalesce(ls.estado,''))='COMPLETADA'
   group by 1 order by 1 desc`)).rows);

console.log('\n── el pickup acumulado que SÍ existe: ¿cuándo se creó?');
console.table((await c.query(`
  select id_pickup, estado, id_zona, jsonb_array_length(coalesce(items,'[]'::jsonb)) n,
         to_char(fecha_creado at time zone 'America/Lima','YYYY-MM-DD HH24:MI') creado
    from wh.pickups where id_pickup like 'PCK-LSC-%' order by fecha_creado desc`)).rows);

// ¿las sombras viejas tenían faltante que registrar? (pedido > despachado)
console.log('\n── de las sombras SIN acumulado, ¿cuántas tenían faltante real?');
console.table((await c.query(`
  with s as (
    select ls.id_lista,
           to_char(coalesce(ls.fecha_completada) at time zone 'America/Lima','YYYY-MM-DD') dia,
           (select count(*) from jsonb_array_elements(coalesce(ls.items,'[]'::jsonb)) it
             where wh._num(coalesce(it->>'cantidad','0')) > wh._num(coalesce(it->>'despachado','0'))) n_faltante
      from wh.listas_sombra ls
     where upper(coalesce(ls.estado,''))='COMPLETADA'
       and not exists (select 1 from wh.pickups pk where pk.id_pickup='PCK-LSC-'||ls.id_lista))
  select dia, count(*) sombras_sin_acum, sum(n_faltante) items_con_faltante from s group by 1 order by 1 desc limit 12`)).rows);
await c.end();
