// 659 · Decisión del dueño (2026-08-08): en auditoría LO CONTADO MANDA — sin tolerancia 0.5.
//   Toda cantidad a 2 decimales (entero o granel) para que el historial "se vea correcto, lo real siempre".
//   Antes: abs(dif)<=0.5 → 'OK' sin mover stock (a Jorgenis le pasó 4 veces con granel).
//   Ahora: dif = round(fisico,2) - round(sistema,2); si round(dif,2) <> 0 → SIEMPRE ajusta.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const def = async () => (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='wh' and p.proname='auditar_producto'`)).rows[0].d;

let d = await def();
if (d.includes('[659]')) { console.log('ya aplicado'); await c.end(); process.exit(0); }
const P = (a, b, tag) => { const i = d.indexOf(a); if (i < 0) throw new Error('NO: ' + tag); if (d.indexOf(a, i + 1) >= 0) throw new Error('DUP: ' + tag); d = d.slice(0, i) + b + d.slice(i + a.length); };

P(`  v_diff := v_fisico - v_sistema;
  v_result := case when abs(v_diff) <= 0.5 then 'OK' else 'DIFERENCIA' end;`,
`  -- [659] LO CONTADO MANDA (decisión dueño): sin tolerancia; todo a 2 decimales (historial fiel).
  v_fisico := round(v_fisico, 2);
  v_diff := round(v_fisico - v_sistema, 2);
  v_result := case when v_diff = 0 then 'OK' else 'DIFERENCIA' end;`, 'tolerancia');
P(`  if abs(v_diff) > 0.5 then`, `  if v_diff <> 0 then`, 'gate ajuste');
P(`'ajusto',abs(v_diff) > 0.5`, `'ajusto',v_diff <> 0`, 'flag return');

// test en tx con producto real de granel
await c.query('begin');
await c.query(d);
const { rows: [pr] } = await c.query(`select s.cod_producto cod, s.cantidad_disponible as stock from wh.stock s where s.cantidad_disponible <> round(s.cantidad_disponible,0) limit 1`);
console.log('conejillo granel:', pr.cod, 'stock', pr.stock);
const fis = (parseFloat(pr.stock) + 0.27).toFixed(3); // dif 0.27 — antes NO corregía
const { rows: [{ r }] } = await c.query(`select wh.auditar_producto(jsonb_build_object('codigo_barra',$1::text,'stock_fisico',$2::numeric,'usuario','TEST-659','observacion','test 659','id_auditoria','AUDTEST659')) r`, [pr.cod, fis]);
console.log('resultado RPC:', JSON.stringify(r).slice(0, 180));
const { rows: [st] } = await c.query(`select cantidad_disponible as stock from wh.stock where cod_producto=$1`, [pr.cod]);
const esperado = Math.round((parseFloat(pr.stock) + 0.27) * 100) / 100;
console.log('stock tras auditar:', st.stock, '· esperado (2 dec):', esperado);
const { rows: [mv] } = await c.query(`select cantidad_ajuste from wh.ajustes where usuario='TEST-659' or id_auditoria like '%' order by fecha desc limit 1`);
console.log('ajuste registrado:', mv && mv.cantidad_ajuste);
const okAjusto = r.ajusto === true && r.resultado === 'DIFERENCIA';
const okStock = Math.abs(parseFloat(st.stock) - esperado) < 0.005;
const okDec = String(r.diferencia).split('.')[1]?.length <= 2 || Number.isInteger(r.diferencia);
console.log(okAjusto && okStock && okDec ? '✅ dif 0.27 AHORA SÍ corrige, a 2 decimales' : `❌ ajusto=${r.ajusto} stock=${st.stock} dec=${okDec}`);
// caso dif=0 exacto: no debe crear ajuste
const { rows: [{ r: r2 }] } = await c.query(`select wh.auditar_producto(jsonb_build_object('codigo_barra',$1::text,'stock_fisico',$2::numeric,'usuario','TEST-659b','observacion','test dif0','id_auditoria','AUDTEST659B')) r`, [pr.cod, st.stock]);
console.log('dif 0 →', r2.resultado, '· ajusto:', r2.ajusto, r2.resultado === 'OK' && !r2.ajusto ? '✅' : '❌');
await c.query('rollback');
if (!(okAjusto && okStock && okDec) || r2.resultado !== 'OK') { console.log('NO SE APLICA'); process.exit(1); }
await c.query(d);
console.log('✅ 659 APLICADO — lo contado manda, 2 decimales, historial fiel');
await c.end();
