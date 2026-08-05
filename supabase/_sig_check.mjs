import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
console.table((await c.query(`select n.nspname sch, p.proname fn, pg_get_function_identity_arguments(p.oid) args
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where p.proname in ('datos_turno','confirmar_cobro','cobrar_credito_directo','marcar_pagos','fac_pdf_por_venta')
 order by 1,2`)).rows);
await c.end();
