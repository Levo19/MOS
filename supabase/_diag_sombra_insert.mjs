// ¿Por qué falla el insert del acumulado al cerrar una sombra? Reproducimos el INSERT
// exacto en tx+ROLLBACK con datos de una sombra real, SIN el `exception when others`.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

console.log('── columnas reales de wh.pickups:');
const cols = (await c.query(`select column_name, is_nullable, data_type, column_default
  from information_schema.columns where table_schema='wh' and table_name='pickups' order by ordinal_position`)).rows;
console.table(cols);

const req = cols.filter(x => x.is_nullable === 'NO' && !x.column_default).map(x => x.column_name);
console.log('columnas OBLIGATORIAS sin default:', req.join(', ') || '(ninguna)');

console.log('\n── el INSERT que hace cerrar_lista_sombra, sin tragar el error:');
await c.query('begin');
try {
  await c.query(`insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
    values ('PCK-LSC-DIAG-617','LISTA_IA','PENDIENTE','[{"skuBase":"X","solicitado":1,"despachado":0}]'::jsonb,
            'ZONA-02','diag','sistema', now(), now())`);
  console.log('  ✔ el insert FUNCIONA (el error debe estar antes, en el armado de v_pick)');
} catch (e) {
  console.log('  ❌ EL INSERT FALLA →', e.message);
  console.log('     detail:', e.detail || '-', '| column:', e.column || '-', '| constraint:', e.constraint || '-');
}
await c.query('rollback');

console.log('\n── las 33 sombras COMPLETADA: ¿tenían items al cerrar?');
console.table((await c.query(`
  select ls.id_lista, ls.zona, upper(ls.estado) estado,
         jsonb_array_length(coalesce(ls.items,'[]'::jsonb)) n_items,
         (select count(*) from wh.pickups pk where pk.id_pickup='PCK-LSC-'||ls.id_lista) tiene_acum,
         to_char(ls.fecha_creacion at time zone 'America/Lima','DD/MM') creada
    from wh.listas_sombra ls
   where upper(coalesce(ls.estado,''))='COMPLETADA'
   order by ls.fecha_creacion desc limit 8`)).rows);
await c.end();
