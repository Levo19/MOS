// 1) Anular las 3 sombras restantes de ayer (todas con 0 escaneos — seguro) liberando el candado de Sergio.
// 2) Confirmar el estado del acumulador ZONA-01 recién nacido.
// 3) Listar las RPCs de sombra (para colgar ultima_actividad).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const upd = await c.query(`
  update wh.listas_sombra
     set estado = 'ANULADA', fecha_completada = now(),
         nota = coalesce(nota,'') || ' [anulada manual 2026-08-01 por el dueño: sin escaneos, subida duplicada/errada]'
   where id_lista in ('LS1785528099523','LS1785526471364','LS1785518461547')
     and upper(coalesce(estado,'')) in ('DISPONIBLE','EN_USO')
     and not exists (select 1 from jsonb_array_elements(coalesce(items,'[]'::jsonb)) it
                      where wh._num(coalesce(it->>'cantidadEscaneada','0')) > 0)   -- guard: solo si siguen sin escaneos
  returning id_lista, estado`);
console.table(upd.rows);
console.log('— sombras vivas ahora (debe ser 0):');
console.table((await c.query(`select id_lista, estado from wh.listas_sombra where upper(coalesce(estado,'')) in ('DISPONIBLE','EN_USO')`)).rows);
console.log('— acumulador ZONA-01 (el "pedido" que apareció):');
console.table((await c.query(`
  select id_pickup, estado, jsonb_array_length(items) n_items,
         (select round(sum(greatest(0,(it->>'solicitado')::numeric - coalesce((it->>'despachado')::numeric,0))),1)
            from jsonb_array_elements(items) it) uds_debidas
    from wh.pickups where id_pickup='PCK-ACU-ZONA-01-2026-07-26'`)).rows);
console.log('— RPCs de sombra existentes:');
console.log((await c.query(`select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='wh' and p.proname ilike '%sombra%' order by 1`)).rows.map(r => r.proname).join(' · '));
await c.end();
