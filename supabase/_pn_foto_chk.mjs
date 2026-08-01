// ¿La foto del PN llega al producto aprobado? Caso Nescafé + las aguas de hoy.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
console.log('— PN nescafé/aguas (foto en el PN):');
console.table((await c.query(`
  select id_producto_nuevo, descripcion, codigo_barra, estado,
         case when coalesce(foto,'')='' then '(SIN FOTO)' else left(foto,60) end foto
    from wh.producto_nuevo
   where descripcion ilike '%nescafe%' or descripcion ilike '%agua%'
   order by fecha_registro desc limit 6`)).rows);
console.log('— productos creados (foto_url en el catálogo):');
console.table((await c.query(`
  select p.codigo_barra, p.descripcion,
         case when coalesce(p.foto_url,'')='' then '(SIN FOTO)' else left(p.foto_url,60) end foto_url
    from mos.productos p
   where p.codigo_barra in (select btrim(codigo_barra) from wh.producto_nuevo
                             where descripcion ilike '%nescafe%' or descripcion ilike '%agua%')
   order by p.fecha_creacion desc limit 6`)).rows);
console.log('— dimensión del hueco: PN APROBADOS con foto Storage cuyo producto quedó SIN foto:');
console.table((await c.query(`
  select count(*) n
    from wh.producto_nuevo pn
    join mos.productos p on btrim(p.codigo_barra) = btrim(pn.codigo_barra)
   where upper(coalesce(pn.estado,'')) = 'APROBADO'
     and coalesce(pn.foto,'') like '%supabase.co/storage%'
     and coalesce(p.foto_url,'') = ''`)).rows);
await c.end();
