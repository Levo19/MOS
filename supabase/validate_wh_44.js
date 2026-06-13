const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass','utf8').trim();
const c = new Client({ host:'aws-1-us-east-1.pooler.supabase.com', port:5432, user:'postgres.rzbzdeipbtqkzjqdchqk', password:PASS, database:'postgres', ssl:{rejectUnauthorized:false} });
const q=(s,a)=>c.query(s,a); const rpc=async(p)=>(await q(`select wh.marcar_producto_nuevo_aprobado($1::jsonb) r`,[JSON.stringify(p)])).rows[0].r;
let pass=0,fail=0; const chk=(n,cond,ex)=>{cond?(pass++,console.log('  ✅',n)):(fail++,console.log('  ❌',n,JSON.stringify(ex)||''));};
(async()=>{ await c.connect();
  try { await q('begin'); await q(`update mos.config set valor='1' where clave in ('WH_CREAR_PREINGRESO_DIRECTO','WH_MARCAR_PRODUCTO_NUEVO_APROBADO_DIRECTO')`);
    await q(`insert into wh.producto_nuevo(id_producto_nuevo,descripcion,codigo_barra,estado,usuario) values('PNT','test','C9','PENDIENTE','v')`);
    let r=await rpc({id_producto_nuevo:'PNT',aprobado_por:'admin',observacion:'EQUIVALENTE de X'});
    chk('marca APROBADO ok', r.ok&&r.dedup===false, r);
    let row=(await q(`select estado,aprobado_por,observacion,fecha_aprobacion from wh.producto_nuevo where id_producto_nuevo='PNT'`)).rows[0];
    chk('estado APROBADO + campos', row.estado==='APROBADO'&&row.aprobado_por==='admin'&&row.observacion==='EQUIVALENTE de X'&&row.fecha_aprobacion!==null, row);
    r=await rpc({id_producto_nuevo:'PNT'}); chk('idempotencia dedup', r.dedup===true, r);
    r=await rpc({id_producto_nuevo:'NOEX'}); chk('inexistente rechazado', r.error==='PRODUCTO_NUEVO_NO_ENCONTRADO', r);
    r=await rpc({}); chk('falta id rechazado', r.error==='FALTAN_PARAMS', r);
    console.log(`\n${fail===0?'✅ TODOS':'❌ FALLOS'} — pass:${pass} fail:${fail}`);
  } catch(e){ console.error('❌ ERROR:',e.message); fail++; } finally { await q('rollback').catch(()=>{}); await c.end(); console.log('(rollback)'); }
})();
