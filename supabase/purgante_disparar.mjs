// PURGANTE · DISPARO — un solo paso. Ordena a TODA la flota (MOS · ME · MosGo)
// purgarse UNA vez al siguiente arranque.
//
//   ARMAR (dispara de verdad):
//     node "C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/purgante_disparar.mjs" --apply
//
//   ENSAYO (no toca nada, muestra qué haría):
//     node "C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/purgante_disparar.mjs"
//
//   DESARMAR / CANCELAR (vuelve a dormir; los que ya se purgaron no se re-purgan):
//     node "C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/purgante_disparar.mjs" --desarmar --apply
//
// El token es el epoch en segundos del disparo: es monótono (siempre distinto del
// anterior) y legible — dice CUÁNDO se ordenó la purga.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;

const APPLY    = process.argv.includes('--apply');
const DESARMAR = process.argv.includes('--desarmar');

const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const actual = (await c.query(`select valor from mos.config where clave='MOS_PURGANTE_TOKEN'`)).rows[0];
if (!actual) { console.log('🔴 MOS_PURGANTE_TOKEN no existe. Corre antes: node 658_purgante.mjs --apply'); await c.end(); process.exit(1); }

const nuevo = DESARMAR ? '0' : String(Math.floor(Date.now() / 1000));

console.log('token actual : ' + actual.valor + (actual.valor === '0' ? '  (DORMIDO)' : '  (ARMADO)'));
console.log('token nuevo  : ' + nuevo   + (nuevo === '0' ? '  (DORMIDO)' : '  (ARMADO · ' + new Date(+nuevo * 1000).toISOString() + ')'));

if (!APPLY) {
  const E = (await c.query(`select mos.purgante_estado($1::jsonb) r`, [JSON.stringify({ dias: 30 })])).rows[0].r;
  console.log('\nequipos ACTIVOS que recibirían la orden: ' + E.total);
  console.log('\n🟡 ENSAYO. Nada cambió. Agrega --apply para disparar de verdad.');
  await c.end(); process.exit(0);
}

await c.query(`update mos.config set valor=$1 where clave='MOS_PURGANTE_TOKEN'`, [nuevo]);
const ver = (await c.query(`select mos.get_flags() f`)).rows[0].f.purganteToken;
if (ver !== nuevo) { console.log('🔴 get_flags NO devuelve el token nuevo (' + ver + '). Revisa mos.get_flags.'); await c.end(); process.exit(1); }

const E = (await c.query(`select mos.purgante_estado($1::jsonb) r`, [JSON.stringify({ dias: 30 })])).rows[0].r;
console.log('\n' + (DESARMAR ? '🟢 PURGANTE DESARMADO — nadie hará nada.'
                             : '🟢 PURGANTE ARMADO. ' + E.total + ' equipos ACTIVOS se purgarán al abrir la app.'));
if (!DESARMAR) console.log('   Avance:  node "C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/purgante_estado.mjs"');
await c.end();
