import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const r = await c.query(`
  select table_schema||'.'||table_name tabla, column_name, data_type, numeric_precision, numeric_scale
    from information_schema.columns
   where (table_schema='wh' and table_name in ('stock','guia_detalle','stock_movimientos','envasados')
          and column_name in ('cantidad_disponible','cant_esperada','cant_recibida','delta','stock_antes','stock_despues','cantidad_base','unidades_producidas','unidades_esperadas'))
   order by 1, 2`);
console.table(r.rows);
await c.end();
