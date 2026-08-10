import { chromium } from 'playwright';
import path from 'path'; import fs from 'fs';
import { fileURLToPath } from 'url';
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const URL = 'https://levo19.github.io/warehouseMos-/';
const DEV = '7e57c1a0-de1c-4a7e-b0de-c47a10906475';
const SESION = JSON.stringify({ idSesion:'LOCAL_TESTCLAUDE', idPersonal:'TEST-CLAUDE', nombre:'PRUEBA CLAUDE',
  apellido:'CLAUDE', color:'#4f46e5', rol:'MASTER', fechaDia:'2026-08-09', fechaGuardado:new Date().toISOString() });

(async () => {
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport:{width:1280,height:900} });
  const page = await ctx.newPage();
  const errs = []; page.on('pageerror', e => errs.push(e.message));
  await page.addInitScript(([d,s]) => {
    localStorage.setItem('wh_device_id', d); localStorage.setItem('wh_sesion', s);
    localStorage.setItem('wh_last_activity', String(Date.now()));
  }, [DEV, SESION]);
  await page.goto(URL, { waitUntil:'domcontentloaded', timeout:45000 });
  await page.waitForTimeout(28000);

  const r = await page.evaluate(() => {
    const prods = OfflineManager.getProductosCache() || [];
    const eqs   = OfflineManager.getEquivalenciasCache() || [];
    const raices = ['7758725000036','7750464444799','737186519674','7751304240502',
                    '7751020300016','6123228926663','6920619591376','3025258588596'];
    const hit = (arr, campo) => {
      const o = {};
      raices.forEach(rz => {
        o[rz] = arr.filter(p => String(p[campo]||'').trim().toUpperCase().startsWith(rz))
                   .map(p => ({ cb:p.codigoBarra, sku:p.skuBase, id:p.idProducto,
                                fc:p.factorConversion, est:p.estado,
                                d:String(p.descripcion||'').slice(0,40) }));
      });
      return o;
    };
    const out = {
      nProds: prods.length, nEqs: eqs.length,
      muestraProd: prods[0] ? Object.keys(prods[0]) : [],
      enProductos: hit(prods, 'codigoBarra'),
      enEquivs:    hit(eqs, 'codigoBarra'),
      estadosDistintos: [...new Set(prods.map(p => String(p.estado)))].slice(0,8),
      factores: [...new Set(prods.map(p => String(p.factorConversion)))].slice(0,10)
    };
    // ¿qué dice el módulo?
    if (window.FamiliaCB) {
      out.fam = {};
      raices.forEach(rz => {
        out.fam[rz] = { raiz: FamiliaCB.raiz(rz), n: FamiliaCB.familia(rz).length,
                        nInact: FamiliaCB.familia(rz, {incluirInactivos:true}).length };
      });
    }
    // Barrido real de sufijos en todo el catálogo
    const conLetra = prods.filter(p => /[0-9]{6,}[A-Za-z]{1,2}$/.test(String(p.codigoBarra||'').trim()));
    out.conLetraTotal = conLetra.length;
    out.conLetraMuestra = conLetra.slice(0,25).map(p => p.codigoBarra + ' | ' + String(p.descripcion||'').slice(0,34));
    return out;
  });
  r.pageerrors = errs;
  fs.writeFileSync(path.join(__dirname,'_544_probe.json'), JSON.stringify(r,null,2));
  console.log(JSON.stringify(r,null,2).slice(0, 9000));
  await browser.close();
})().catch(e => { console.error('FALLO', e); process.exit(1); });
