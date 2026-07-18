// Convierte 5 productos mal tipeados (CANONICO basura) a su tipo correcto + elimina 1 (taper).
// node _conv_mistipeados.js         → dry-run
// node _conv_mistipeados.js --apply → aplica (tx única, reversa en _conv_mistipeados_plan.json)
const {Client}=require("C:/Users/ISO/ProyectoMOS/node_modules/pg");const fs=require("fs");
const APPLY=process.argv.includes('--apply');
const c=new Client({connectionString:fs.readFileSync("C:/Users/ISO/.sb_db.url","utf8").trim()});
function _slug(pd){var s=String(pd||'').toUpperCase().normalize('NFD').replace(/[̀-ͯ]/g,'');s=s.replace(/[^A-Z0-9 ]/g,' ');var ps=s.split(/\s+/).filter(Boolean),le='',nu='';for(var w of ps){var d=w.replace(/[^0-9]/g,'');if(d)nu+=d;var L=w.replace(/[^A-Z]/g,'');if(L&&le.length<6){le+=(L[0]+L.slice(1).replace(/[AEIOU]/g,'')).slice(0,3);}}return(le.slice(0,6)+nu.slice(0,4))||'PRES';}
function _codP(padre,suf){var b=Math.max(3,13-3-suf.length);return 'P-'+_slug(padre).slice(0,b)+'-'+suf;}
function _codW(padre,suf){var b=Math.max(3,13-3-suf.length);return 'WH-'+_slug(padre).slice(0,b)+suf;}
(async()=>{await c.connect();
  const canon=async cod=>(await c.query("select id_producto,sku_base,descripcion,codigo_barra from mos.productos where codigo_barra=$1",[cod])).rows[0];
  const manga=await canon('00656'), azucar=await canon('7750243069458'), perla=await canon('00612');
  const conv=[
    {cod:'PRE225', tipo:'PRESENTACION', factor:3,   base:manga},
    {cod:'PRE467', tipo:'PRESENTACION', factor:100, base:manga},
    {cod:'PRE263', tipo:'DERIVADO',     kg:0.5,     base:azucar},
    {cod:'PRE478', tipo:'DERIVADO',     kg:0.25,    base:azucar},
    {cod:'PRE556', tipo:'DERIVADO',     kg:5,       base:azucar}
  ];
  const plan=[];
  for(const it of conv){
    const p=(await c.query("select id_producto,codigo_barra,descripcion,precio_venta,sku_base from mos.productos where codigo_barra=$1",[it.cod])).rows[0];
    let row={id:p.id_producto, codViejo:p.codigo_barra, nomViejo:p.descripcion, tipo:it.tipo};
    if(it.tipo==='PRESENTACION'){
      row.codNuevo=_codP(it.base.descripcion,'X'+it.factor);
      row.nomNuevo=it.base.descripcion+' · Pack x'+it.factor+' ('+it.factor+' un)';
      row.set={tipo_producto:'PRESENTACION', factor_conversion:it.factor, factor_conversion_base:null,
               codigo_producto_base:null, sku_base:p.sku_base, es_envasable:false, unidad_medida:'NIU'};
    } else {
      const gr=it.kg>=1?(it.kg+'KG'):(Math.round(it.kg*1000)+'GR');
      const baseLimpia=it.base.descripcion.replace(/\bGRANEL\b/ig,'').replace(/\s+/g,' ').trim();
      row.codNuevo=_codW(baseLimpia,'D'+Math.round(it.kg*1000));
      row.nomNuevo=baseLimpia+' '+gr;
      const nuevoSku='LEV'+String((await c.query("select nextval('mos.seq_producto') n")).rows[0].n).padStart(7,'0');
      row.set={tipo_producto:'DERIVADO', codigo_producto_base:it.base.sku_base, factor_conversion_base:it.kg,
               factor_conversion:null, sku_base:nuevoSku, es_envasable:false, unidad_medida:'NIU'};
      row.skuNuevo=nuevoSku;
    }
    plan.push(row);
  }
  // PRE461 taper → eliminar (reescribir venta al granel perla + desactivar)
  const tap=(await c.query("select id_producto,codigo_barra,descripcion,estado from mos.productos where codigo_barra='PRE461'")).rows[0];
  const tapPlan={id:tap.id_producto, codViejo:tap.codigo_barra, accion:'ELIMINAR(desactivar)+venta→'+perla.codigo_barra, estadoViejo:tap.estado};

  console.log("=== CONVERSIONES ===");
  plan.forEach(r=>console.log(`  ${r.codViejo} → ${r.tipo} | ${r.codNuevo} (${r.codNuevo.length}) | "${r.nomNuevo}"${r.skuNuevo?' | skuNuevo='+r.skuNuevo:''}`));
  console.log("=== ELIMINAR ===");
  console.log(`  ${tapPlan.codViejo} "${tap.descripcion}" → desactivar + su venta al granel ${perla.codigo_barra}`);
  fs.writeFileSync(__dirname+"/_conv_mistipeados_plan.json", JSON.stringify({plan,tapPlan},null,1),"utf8");

  if(!APPLY){ console.log("\n(DRY-RUN — nada aplicado. --apply para ejecutar.)"); await c.end(); return; }
  await c.query('begin');
  let np=0,nv=0;
  for(const r of plan){
    const s=r.set;
    await c.query(`update mos.productos set tipo_producto=$1, factor_conversion=$2, factor_conversion_base=$3,
      codigo_producto_base=$4, sku_base=$5, es_envasable=$6, unidad_medida=$7, codigo_barra=$8, descripcion=$9
      where id_producto=$10`,
      [s.tipo_producto,s.factor_conversion,s.factor_conversion_base,s.codigo_producto_base,s.sku_base,
       s.es_envasable,s.unidad_medida,r.codNuevo,r.nomNuevo,r.id]); np++;
    const rv=await c.query("update me.ventas_detalle set cod_barras=$1 where upper(btrim(cod_barras))=upper(btrim($2))",[r.codNuevo,r.codViejo]); nv+=rv.rowCount;
  }
  // taper
  const rvt=await c.query("update me.ventas_detalle set cod_barras=$1 where upper(btrim(cod_barras))=upper(btrim('PRE461'))",[perla.codigo_barra]);
  await c.query("update mos.productos set estado=false where codigo_barra='PRE461'");
  await c.query('commit');
  console.log(`\n✅ APLICADO: ${np} conversiones + ${nv} ventas reescritas · taper desactivado (${rvt.rowCount} venta→granel).`);
  await c.end();
})().catch(async e=>{try{await c.query('rollback');}catch(_){}console.error("ERR:",e.message);process.exit(1);});
