// [punto 18] MIGRACIÓN de códigos/nombres de PRESENTACIONES — DRY-RUN (lectura, cero cambios).
//   node _migracion_pres_codigos_dryrun.js          → dry-run (default)
//   node _migracion_pres_codigos_dryrun.js --apply   → APLICA (rewrite productos + ventas_detalle en 1 tx)
// Recalcula: código nuevo = P-<slug(padre)>-<sufijoFactor> · nombre nuevo = "BASE · DESCRIPTOR (CONTENIDO)".
// Reescribe también me.ventas_detalle.cod_barras (para no de-linkear la rotación del padre). Sin alias.
const {Client}=require("C:/Users/ISO/ProyectoMOS/node_modules/pg");
const fs=require("fs");
const APPLY = process.argv.includes('--apply');
const cs=fs.readFileSync("C:/Users/ISO/.sb_db.url","utf8").trim();

// ── helpers (copia fiel de app.js [pres-v1]) ──
function _pesoDesdeNombre(n){const s=String(n||'').toUpperCase();let m=s.match(/([0-9]+(?:[.,][0-9]+)?)\s*(?:KILOS?|KGS?|K)\b/);if(m)return parseFloat(m[1].replace(',','.'));m=s.match(/([0-9]+(?:[.,][0-9]+)?)\s*GR?S?\b/);if(m)return parseFloat(m[1].replace(',','.'))/1000;return null;}
const _PACKS={2:'Dúo',3:'Tripack',6:'Sixpack',12:'Docena'},_FRACC={2:'Media',3:'Tercio',4:'Cuarto',6:'Sexto',8:'Octavo'};
function _den(f){f=parseFloat(f)||0;if(f<=0||f>=1)return null;var inv=1/f,n=Math.round(inv);return(n>=2&&Math.abs(inv-n)<1e-6)?n:null;}
function _desc(f){f=parseFloat(f)||0;if(f>1&&Number.isInteger(f))return _PACKS[f]||('Pack x'+f);var n=_den(f);if(n)return _FRACC[n]||('1/'+n);return '';}
function _suf(f){f=parseFloat(f)||0;if(f<=0)return '';if(f>=1&&Number.isInteger(f))return 'X'+f;var n=_den(f);if(n)return 'D'+n;return 'F'+Math.round(f*1000);}
function _fmtKg(kg){if(!(kg>0))return '';if(kg>=1)return String(Math.round(kg*1000)/1000).replace(/\.?0+$/,'')+' kg';return Math.round(kg*1000)+' g';}
function _cont(pd,f){f=parseFloat(f)||0;if(f<=0)return '';if(f>1)return(Number.isInteger(f)?f:(Math.round(f*100)/100))+' un';var kb=_pesoDesdeNombre(pd);if(kb)return _fmtKg(kb*f);return _fmtKg(f);/*granel: el factor YA es kg (1/200 de 1kg = 5g)*/}
// Nombre de presentación migrado: packs/fracciones NOMBRADAS → "BASE · Tripack (3 un)".
// Fracción "rara" (sachet de granel, factor 1/200) → usar el PESO como descriptor y quitar GRANEL:
// "ANIS ESTRELLA ENTERO · 5 g". Determinista desde (padre, factor).
function _nombreMigrado(padre,factor){
  if(!padre)return null;
  // Una presentación es SIEMPRE un empaque (no granel) → quitar "GRANEL" de la base en todos los casos.
  var base=String(padre).replace(/\bGRANEL\b/ig,'').replace(/\s+/g,' ').trim();
  var d=_desc(factor), cont=_cont(padre,factor);
  var nombrada = d && !/^1\//.test(d);        // nombre lindo (Tripack/Octavo/Pack xN), no "1/N"
  if(nombrada) return _nombre(base,d,cont);   // "BASE · Tripack (3 un)" / "BASE · Media (500 g)"
  if(cont) return _nombre(base,cont,'');       // sachet sin nombre lindo → peso como descriptor: "BASE · 5 g"
  return _nombre(base,d,'');
}
function _slug(pd){var s=String(pd==null?'':pd).toUpperCase().normalize('NFD').replace(/[̀-ͯ]/g,'');s=s.replace(/[^A-Z0-9 ]/g,' ');var ps=s.split(/\s+/).filter(Boolean),le='',nu='';for(var i=0;i<ps.length;i++){var w=ps[i];var d=w.replace(/[^0-9]/g,'');if(d)nu+=d;var L=w.replace(/[^A-Z]/g,'');if(L&&le.length<6){var c=L.charAt(0)+L.slice(1).replace(/[AEIOU]/g,'');le+=c.slice(0,3);}}return(le.slice(0,6)+nu.slice(0,4))||'PRES';}
// Código ≤13 chars (límite scannable CODE128 en el adhesivo 50mm). P-<slug>-<suf>, slug recortado al presupuesto.
// Colisión: se reserva 1 char del slug para un contador base36 (mantiene el largo). taken = Set de códigos usados.
const _B36='0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
function _codigoPres(padre, factor, taken, viejo){
  const MAX=13, suf=_suf(factor), slugF=_slug(padre);
  const budget=Math.max(3, MAX-3-suf.length);
  let cand='P-'+slugF.slice(0,budget)+(suf?('-'+suf):'');
  const libre=x=>!taken.has(x.toUpperCase())||x.toUpperCase()===String(viejo||'').toUpperCase();
  if(libre(cand))return cand;
  const slugBase=slugF.slice(0,Math.max(2,budget-1));
  for(let k=0;k<_B36.length;k++){cand='P-'+slugBase+_B36[k]+(suf?('-'+suf):'');if(libre(cand))return cand;}
  for(let k=2;k<80;k++){cand='P-'+slugF.slice(0,budget)+(suf?('-'+suf):'')+k;if(libre(cand))return cand;}
  return cand;
}
function _nombre(pd,d,c){var b=String(pd==null?'':pd).toUpperCase().replace(/\s+/g,' ').trim();d=String(d==null?'':d).trim();if(!d)return b;if(c)d=d+' ('+c+')';return b?(b+' · '+d):d;}

const c=new Client({connectionString:cs});
(async()=>{
  await c.connect();
  // presentaciones + su canónico (padre) del grupo (factor=1, sin codigo_producto_base preferido)
  const rows=(await c.query(`
    select pr.id_producto, pr.codigo_barra cod, pr.descripcion, pr.factor_conversion factor, pr.sku_base,
      (select cx.descripcion from mos.productos cx
        where coalesce(nullif(btrim(cx.sku_base),''),cx.id_producto)=coalesce(nullif(btrim(pr.sku_base),''),pr.id_producto)
          and coalesce(nullif(cx.factor_conversion,0),1)=1
        order by (coalesce(nullif(btrim(cx.codigo_producto_base),''),'')='') desc limit 1) padre_desc
    from mos.productos pr where pr.tipo_producto='PRESENTACION' order by pr.codigo_barra`)).rows;

  // códigos ya usados en TODO el catálogo (para no colisionar) + equivalencias
  const usados=new Set((await c.query(`select upper(btrim(codigo_barra)) cb from mos.productos where nullif(btrim(codigo_barra),'') is not null`)).rows.map(r=>r.cb));
  (await c.query(`select upper(btrim(codigo_barra)) cb from mos.equivalencias where nullif(btrim(codigo_barra),'') is not null`)).rows.forEach(r=>usados.add(r.cb));
  // ventas por código viejo
  const vd=new Map();(await c.query(`select upper(btrim(cod_barras)) cb, count(*) n from me.ventas_detalle where nullif(btrim(cod_barras),'') is not null group by 1`)).rows.forEach(r=>vd.set(r.cb,+r.n));

  const nuevos=new Set(), plan=[]; let sinPadre=0, sinCambio=0, conVentas=0, colision=0;
  for(const r of rows){
    const factor=parseFloat(r.factor)||0;
    const padre=r.padre_desc||'';
    if(!padre){sinPadre++;}
    const viejo=String(r.cod||'').toUpperCase();
    // taken = catálogo actual (menos el propio código viejo) + los ya asignados en esta corrida
    const taken=new Set([...usados, ...nuevos]); taken.delete(viejo);
    const cand=_codigoPres(padre||r.descripcion, factor, taken, viejo);
    if(cand.length>13)colision++;   // no debería pasar
    nuevos.add(cand.toUpperCase());
    const nombreNuevo=padre?_nombreMigrado(padre,factor):r.descripcion;
    const nVentas=vd.get(viejo)||0; if(nVentas>0)conVentas++;
    const cambia=(cand.toUpperCase()!==viejo)||(nombreNuevo!==r.descripcion);
    if(!cambia)sinCambio++;
    plan.push({id:r.id_producto,codViejo:r.cod,codNuevo:cand,nomViejo:r.descripcion,nomNuevo:nombreNuevo,factor,padre,nVentas,cambia});
  }
  console.log(`\n===== DRY-RUN migración presentaciones (${rows.length}) =====`);
  console.log(`sin padre resuelto: ${sinPadre} | sin cambio: ${sinCambio} | con ventas (rewrite ventas_detalle): ${conVentas} | colisiones sin resolver: ${colision}`);
  console.log(`\nMuestra (20 que cambian):`);
  plan.filter(p=>p.cambia).slice(0,20).forEach(p=>console.log(
    `  ${String(p.codViejo).padEnd(10)} → ${p.codNuevo.padEnd(18)} | ventas:${String(p.nVentas).padStart(3)} | "${(p.nomViejo||'').slice(0,18)}" → "${(p.nomNuevo||'').slice(0,48)}"`));
  fs.writeFileSync(__dirname+"/_migracion_pres_plan.json", JSON.stringify(plan,null,1), "utf8");
  console.log(`\nplan completo → supabase/_migracion_pres_plan.json (${plan.length} filas)`);

  if(!APPLY){ console.log("\n(DRY-RUN — no se aplicó nada. Corré con --apply para ejecutar, con cajas cerradas.)"); await c.end(); return; }

  // ── APPLY (transacción única, reversible por el plan.json) ──
  if(colision){ console.log("\n⚠ Hay colisiones sin resolver — abortando apply."); await c.end(); process.exit(1); }
  await c.query('begin');
  let np=0,nv=0;
  for(const p of plan){ if(!p.cambia)continue;
    const rp=await c.query(`update mos.productos set codigo_barra=$1, descripcion=$2 where id_producto=$3`,[p.codNuevo,p.nomNuevo,p.id]); np+=rp.rowCount;
    if(p.codViejo){ const rv=await c.query(`update me.ventas_detalle set cod_barras=$1 where upper(btrim(cod_barras))=upper(btrim($2))`,[p.codNuevo,p.codViejo]); nv+=rv.rowCount; }
  }
  await c.query('commit');
  console.log(`\n✅ APLICADO: ${np} productos + ${nv} filas ventas_detalle reescritas. Reversa: _migracion_pres_plan.json`);
  await c.end();
})().catch(async e=>{try{await c.query('rollback');}catch(_){}console.error("ERR:",e.message);process.exit(1);});
