// [1053] Runner del ensayo LOCAL (nunca toca lo vivo). Usa el Postgres de ensayos C:/Users/ISO/.levo-pg
// (puerto 54329) respetando su registro de uso; no lo enciende ni lo apaga.
//   node "C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/1053_ensayo_local.cjs"
// Éxito = A OK, B OK, C OK (la guarda aborta UNA vez, a propósito), D OK, "ENSAYO 1053 COMPLETO"
// y ningún otro ERROR (los "current transaction is aborted" de C son la cola de esa misma guarda).
'use strict'
const fs = require('fs')
const path = require('path')
const { spawnSync } = require('child_process')
const HOME = 'C:/Users/ISO/.levo-pg'
const PSQL = path.join(HOME, 'pgsql', 'bin', 'psql.exe')
const PGCTL = path.join(HOME, 'pgsql', 'bin', 'pg_ctl.exe')
if (!fs.existsSync(PSQL)) { console.error('FAIL faltan binarios del Postgres local'); process.exit(2) }
if (spawnSync(PGCTL, ['status', '-D', path.join(HOME, 'data')], { stdio: 'ignore', windowsHide: true }).status !== 0) {
  console.error('FAIL Postgres LOCAL apagado (no se hizo nada)'); process.exit(2)
}
try {
  const USO = require('C:/Users/ISO/levodev-modules/tools/lib/pg_local_uso.cjs')
  USO.esperarSinRecarga(); USO.registrar({ suite: 'mos_1053_ensayo_local', modo: 'runner' })
} catch (_) { /* sin registro de uso: el ensayo es una sola transacción corta */ }
const r = spawnSync(PSQL, ['-h', 'localhost', '-p', '54329', '-U', 'postgres', '-d', process.env.LEVO_PG_DB || 'postgres',
  '-X', '-q', '-At', '-f', path.join(__dirname, '1053_ensayo_local.sql')], { encoding: 'utf8', windowsHide: true, cwd: __dirname })
process.stdout.write(r.stdout || ''); process.stderr.write(r.stderr || '')
const out = r.stdout || ''
const lineas = (r.stderr || '').split('\n').filter(l => l.includes('ERROR:'))
const esGuarda = l => l.includes('1053 ABORTA:') && l.includes('ya tiene RLS')
const guarda = lineas.filter(esGuarda).length
const errores = lineas.filter(l => !esGuarda(l) && !l.includes('current transaction is aborted')).length
const ok = r.status === 0 && ['A OK', 'B OK', 'C OK', 'D OK', 'ENSAYO 1053 COMPLETO'].every(s => out.includes(s)) && guarda === 1 && errores === 0
console.log(ok ? 'RESULTADO: VERDE (guarda de C abortó 1 vez como se espera; 0 errores inesperados)'
  : `RESULTADO: ROJO (status ${r.status}, guarda ${guarda}, errores inesperados ${errores})`)
process.exit(ok ? 0 : 1)
