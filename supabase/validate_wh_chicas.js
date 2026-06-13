const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass', 'utf8').trim();
const c = new Client({ host:'aws-1-us-east-1.pooler.supabase.com', port:5432, user:'postgres.rzbzdeipbtqkzjqdchqk', password:PASS, database:'postgres', ssl:{rejectUnauthorized:false} });
const q=(s,a)=>c.query(s,a);
const rpc=async(fn,p)=>(await q(`select wh.${fn}($1::jsonb) r`,[JSON.stringify(p)])).rows[0].r;
let pass=0,fail=0; const chk=(n,cond,ex)=>{cond?(pass++,console.log('  ✅',n)):(fail++,console.log('  ❌',n,JSON.stringify(ex)||''));};
(async()=>{ await c.connect();
  try { await q('begin');
    await q(`update mos.config set valor='1' where clave in ('WH_CREAR_PREINGRESO_DIRECTO','WH_MARCAR_PREINGRESO_PROCESADO_DIRECTO','WH_CREAR_AUDITORIA_DIRECTO','WH_GET_O_CREAR_GUIA_DIA_DIRECTO')`);

    await rpc('crear_preingreso',{id_preingreso:'PIMARK',id_proveedor:'P1',usuario:'v',monto:'10'});
    let r=await rpc('marcar_preingreso_procesado',{id_preingreso:'PIMARK',id_guia:'GMARK'});
    chk('39 marca PROCESADO+guia', r.ok && r.dedup===false, r);
    let row=(await q(`select estado,id_guia from wh.preingresos where id_preingreso='PIMARK'`)).rows[0];
    chk('39 estado=PROCESADO,id_guia=GMARK', row.estado==='PROCESADO'&&row.id_guia==='GMARK', row);
    r=await rpc('marcar_preingreso_procesado',{id_preingreso:'PIMARK',id_guia:'GMARK'}); chk('39 idempotencia', r.dedup===true, r);
    r=await rpc('marcar_preingreso_procesado',{id_preingreso:'NOEX',id_guia:'G'}); chk('39 inexistente rechazado', r.error==='PREINGRESO_NO_ENCONTRADO', r);

    r=await rpc('crear_auditoria',{id_auditoria:'AUDT',codigo_producto:'C1',usuario:'v',stock_sistema:'5',stock_fisico:'4,5',diferencia:'-0,5',resultado:'DIFERENCIA',estado:'EJECUTADA'});
    chk('40 crea ok', r.ok&&r.dedup===false, r);
    row=(await q(`select * from wh.auditorias where id_auditoria='AUDT'`)).rows[0];
    chk('40 fila correcta (coma decimal)', row&&Number(row.stock_fisico)===4.5&&Number(row.diferencia)===-0.5&&row.estado==='EJECUTADA', row);
    r=await rpc('crear_auditoria',{id_auditoria:'AUDT',codigo_producto:'C1'}); chk('40 idempotencia', r.dedup===true, r);
    r=await rpc('crear_auditoria',{codigo_producto:'C1'}); chk('40 falta id rechazado', r.error==='FALTAN_PARAMS', r);

    // 41: invariante de reuso (robusta a datos reales) — 2 llamadas mismo tipo → MISMA guia
    let r1=await rpc('get_o_crear_guia_dia',{tipo:'SALIDA_DEVOLUCION',usuario:'v',id_guia_nuevo:'GENVA'});
    chk('41 get-o-crear ok', r1.ok && !!r1.id_guia, r1);
    let r2=await rpc('get_o_crear_guia_dia',{tipo:'SALIDA_DEVOLUCION',usuario:'v',id_guia_nuevo:'GENVB'});
    chk('41 reuso: 2da = misma guia que 1ra', r2.id_guia===r1.id_guia && r2.creada===false, {r1:r1.id_guia,r2:r2.id_guia});
    chk('41 GENVB no se crea (reuso)', (await q(`select count(*)::int n from wh.guias where id_guia='GENVB'`)).rows[0].n===0);
    if(r1.creada){ row=(await q(`select estado,monto_total from wh.guias where id_guia=$1`,[r1.id_guia])).rows[0]; chk('41 si creó: CERRADA monto 0', row.estado==='CERRADA'&&Number(row.monto_total)===0, row); }
    else { console.log('  (41 ya existía guia SALIDA_DEVOLUCION hoy → validó el reuso, no la creación)'); }
    r=await rpc('get_o_crear_guia_dia',{tipo:'BASURA',id_guia_nuevo:'X'}); chk('41 tipo invalido rechazado', r.error==='TIPO_INVALIDO', r);

    console.log(`\n${fail===0?'✅ TODOS':'❌ HAY FALLOS'} — pass:${pass} fail:${fail}`);
  } catch(e){ console.error('❌ ERROR:', e.message); fail++; }
  finally { await q('rollback').catch(()=>{}); await c.end(); console.log('(rollback — nada persistió)'); }
})();
