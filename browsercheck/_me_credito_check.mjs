// Verifica el bloqueo de crédito sin cliente + sintaxis de los 11 scripts inline de ME.
import fs from 'fs';
const html = fs.readFileSync('C:/Users/ISO/ecosistema MOS/MosExpress/index.html', 'utf8');
let ok = 0, fail = 0;
const t = (n, c, e) => { if (c) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, e ?? ''); } };

console.log('── sintaxis');
const scripts = [...html.matchAll(/<script(?![^>]*\ssrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
let err = 0;
scripts.forEach((s, i) => { if (!s.trim()) return; try { new Function(s); } catch (e) {
  if (/Unexpected|Invalid|missing/i.test(e.message)) { err++; console.log(`     script #${i}: ${e.message.slice(0,80)}`); } } });
t(`los ${scripts.length} scripts inline parsean`, err === 0, err);

console.log('── crédito sin cliente');
t('el botón se bloquea si es crédito y no hay cliente',
  /\(\(pago\.ventaCreditoDirecto \|\| pago\.metodo === 'CREDITO'\) && !pago\.nombreCliente\)/.test(html));
t('cubre las DOS vías (crédito directo y método CREDITO)',
  /pago\.ventaCreditoDirecto \|\| pago\.metodo === 'CREDITO'/.test(html));
t('se explica al cajero por qué está bloqueado', html.includes('Sin cliente la deuda no se le puede cobrar a nadie'));
t('el aviso solo aparece en ese caso', /v-if="\(pago\.ventaCreditoDirecto \|\| pago\.metodo === 'CREDITO'\) && !pago\.nombreCliente"/.test(html));

console.log('── no se rompió lo anterior');
t('sigue el bloqueo de factura sin cliente', /pago\.tipoDoc === 'FACTURA'[\s\S]{0,90}!pago\.nombreCliente/.test(html));
t('sigue el bloqueo de boleta >= 700', html.includes("pago.tipoDoc === 'BOLETA' && granTotal >= 700"));
t('sigue el guard de vuelto negativo', html.includes('vuelto < 0'));
t('sigue el anti-doble-ticket de impresión', html.includes('_yaSalio'));
t('sigue el precalentado de voz', html.includes('_ttsWarm'));
console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
process.exit(fail === 0 ? 0 : 1);
