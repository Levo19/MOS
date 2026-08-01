// Estado real de las listas sombra vivas + ¿son duplicadas entre sí?
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const rows = (await c.query(`
  select id_lista, estado, usuario_creador, zona, usuario_tomada,
         to_char(fecha_creacion at time zone 'America/Lima','MM-DD HH24:MI') creada,
         round(extract(epoch from (now() - fecha_creacion))/3600, 1) horas,
         jsonb_array_length(coalesce(items,'[]'::jsonb)) n_items,
         (select round(sum(coalesce((it->>'cantidadEscaneada')::numeric,0)),1)
            from jsonb_array_elements(coalesce(items,'[]'::jsonb)) it) escaneado
    from wh.listas_sombra
   where upper(coalesce(estado,'')) in ('DISPONIBLE','EN_USO')
   order by fecha_creacion desc`)).rows;
console.table(rows);
const det = (await c.query(`
  select id_lista, (select string_agg(coalesce(it->>'skuBase', it->>'nombre'), '|' order by coalesce(it->>'skuBase', it->>'nombre'))
                      from jsonb_array_elements(coalesce(items,'[]'::jsonb)) it) firma
    from wh.listas_sombra
   where upper(coalesce(estado,'')) in ('DISPONIBLE','EN_USO')`)).rows;
const firmas = {};
det.forEach(d => { const h = d.firma || '?'; (firmas[h] = firmas[h] || []).push(d.id_lista); });
console.log('grupos por contenido (mismos productos = duplicadas):');
for (const ids of Object.values(firmas)) console.log(' ', ids.length > 1 ? '⚠ DUPLICADAS:' : 'única:', ids.join(' · '));
await c.end();
