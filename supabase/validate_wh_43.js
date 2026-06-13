const { Client } = require('pg'); const fs = require('fs');
const PASS = fs.readFileSync(__dirname + '/.pgpass', 'utf8').trim();
const c = new Client({ host:'aws-1-us-east-1.pooler.supabase.com', port:5432, user:'postgres.rzbzdeipbtqkzjqdchqk', password:PASS, database:'postgres', ssl:{rejectUnauthorized:false} });
const q=(s,a)=>c.query(s,a);
const rpc=async(p)=>(await q(`select wh.agregar_detalle_guia($1::jsonb) r`,[JSON.stringify(p)])).rows[0].r;
const det=async(g)=>(await q(`select linea,cod_producto,cant_recibida,id_detalle,fecha_vencimiento,id_lote from wh.guia_detalle where id_guia=$1 order by linea`,[g])).rows;
const stk=async(cod)=>{const r=await q(`select cantidad_disponible n from wh.stock where cod_producto=$1`,[cod]);return r.rows.length?Number(r.rows[0].n):null;};
let pass=0,fail=0; const chk=(n,cond,ex)=>{cond?(pass++,console.log('  ✅',n)):(fail++,console.log('  ❌',n,JSON.stringify(ex)||''));};
(async()=>{ await c.connect();
  try { await q('begin');
    await q(`update mos.config set valor='1' where clave='WH_AGREGAR_DETALLE_GUIA_DIRECTO'`);
    // guía ABIERTA de prueba
    await q(`insert into wh.guias(id_guia,tipo,fecha,estado,monto_total) values('GAD','INGRESO_PROVEEDOR',now(),'ABIERTA',0)`);
    // INSERT línea 1
    let r=await rpc({id_guia:'GAD',codigo_producto:'CADX',cantidad_recibida:5,precio_unitario:2,id_detalle:'D1',fecha_vencimiento:'2027-03-01'});
    chk('INSERT linea 1 (accion INSERT)', r.ok&&r.accion==='INSERT'&&r.linea===1&&r.aplico_stock===false, r);
    let d=await det('GAD');
    chk('linea guarda id_detalle+fecha', d[0].id_detalle==='D1'&&new Date(d[0].fecha_vencimiento).toISOString().slice(0,10)==='2027-03-01'&&Number(d[0].cant_recibida)===5, d[0]);
    chk('guia ABIERTA: NO tocó stock', (await stk('CADX'))===null);
    // AUTO-SUMA mismo cod
    r=await rpc({id_guia:'GAD',codigo_producto:'CADX',cantidad_recibida:3,id_detalle:'D1b'});
    chk('AUTOSUMA (misma linea, suma)', r.accion==='AUTOSUMA'&&r.linea===1, r);
    d=await det('GAD'); chk('cant_recibida 5+3=8', Number(d[0].cant_recibida)===8&&d.length===1, d);
    // INSERT cod distinto → linea 2
    r=await rpc({id_guia:'GAD',codigo_producto:'CADY',cantidad_recibida:1,id_detalle:'D2'});
    chk('cod distinto → linea 2', r.accion==='INSERT'&&r.linea===2, r);

    // guía CERRADA → ajusta stock
    await q(`insert into wh.guias(id_guia,tipo,fecha,estado,monto_total) values('GADC','INGRESO_PROVEEDOR',now(),'CERRADA',0)`);
    await q(`insert into wh.stock(id_stock,cod_producto,cantidad_disponible,ultima_actualizacion) values('SADC','CADC',10,now())`);
    r=await rpc({id_guia:'GADC',codigo_producto:'CADC',cantidad_recibida:4,id_detalle:'D3',id_mov:'MADC'});
    chk('guia CERRADA: aplico_stock=true', r.aplico_stock===true, r);
    chk('CERRADA INGRESO: stock 10+4=14', (await stk('CADC'))===14);
    let mv=(await q(`select delta,stock_antes,stock_despues from wh.stock_movimientos where id_mov='MADC'`)).rows[0];
    chk('movimiento +4 antes10 despues14', mv&&Number(mv.delta)===4&&Number(mv.stock_despues)===14, mv);

    // rechazos
    r=await rpc({id_guia:'GAD',codigo_producto:'X',cantidad_recibida:-1}); chk('cantidad negativa rechazada', r.error==='CANTIDAD_NEGATIVA', r);
    r=await rpc({id_guia:'NOEX',codigo_producto:'X',cantidad_recibida:1}); chk('guia inexistente rechazada', r.error==='GUIA_NO_ENCONTRADA', r);
    r=await rpc({codigo_producto:'X'}); chk('falta id_guia rechazado', r.error==='FALTAN_PARAMS', r);

    console.log(`\n${fail===0?'✅ TODOS':'❌ HAY FALLOS'} — pass:${pass} fail:${fail}`);
  } catch(e){ console.error('❌ ERROR:', e.message); fail++; }
  finally { await q('rollback').catch(()=>{}); await c.end(); console.log('(rollback — nada persistió)'); }
})();
