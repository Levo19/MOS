// [666] ME · las promociones ahora llevan HORAS (jugada "horas valle").
//   Parche quirúrgico en las DOS funciones de vigencia de promo:
//     · _promoVigente   (catálogo: el badge/cartel de promo)
//     · _promoIsVigente (carrito: el precio que realmente cobra la caja)
//   Hora ACTUAL en TZ Perú contra Hora_Desde/Hora_Hasta. Null/vacío = todo el día (comportamiento de hoy).
import fs from 'fs';
const P = 'C:/Users/ISO/ecosistema MOS/MosExpress/index.html';
let s = fs.readFileSync(P, 'utf8');
const n0 = s.length;
if (s.includes('[666] ventana horaria')) { console.log('ya aplicado'); process.exit(0); }

const GATE = (ind) => `${ind}// [666] ventana horaria (TZ Perú). Sin Hora_Desde/Hora_Hasta ⇒ todo el día.
${ind}const _hd = pr.Hora_Desde ? String(pr.Hora_Desde).substring(0,5) : '';
${ind}const _hh = pr.Hora_Hasta ? String(pr.Hora_Hasta).substring(0,5) : '';
${ind}if (_hd && _hh) {
${ind}    const _ahora = new Date().toLocaleTimeString('en-GB', { timeZone: 'America/Lima', hour12: false, hour: '2-digit', minute: '2-digit' }).substring(0,5);
${ind}    if (_hd <= _hh) { if (_ahora < _hd || _ahora > _hh) return false; }
${ind}    else            { if (_ahora < _hd && _ahora > _hh) return false; }   // ventana que cruza medianoche
${ind}}
`;

const R = (a, b, tag) => {
  const i = s.indexOf(a);
  if (i < 0) throw new Error('ANCLA NO ENCONTRADA [' + tag + ']');
  if (s.indexOf(a, i + 1) >= 0) throw new Error('ANCLA DUPLICADA [' + tag + ']');
  s = s.slice(0, i) + b + s.slice(i + a.length);
};

// 1) catálogo · _promoVigente
R(`                if (desde && _hoyStr < desde) return false;
                if (hasta && _hoyStr > hasta) return false;
                return true;`,
`                if (desde && _hoyStr < desde) return false;
                if (hasta && _hoyStr > hasta) return false;
${GATE('                ')}                return true;`, 'promoVigente');

// 2) carrito · _promoIsVigente (el que decide el precio cobrado)
R(`          if (desde && hoy < desde) return false;
          if (hasta && hoy > hasta) return false;
          return true;`,
`          if (desde && hoy < desde) return false;
          if (hasta && hoy > hasta) return false;
${GATE('          ')}          return true;`, 'promoIsVigente');

fs.writeFileSync(P, s);
console.log('MosExpress/index.html', n0, '->', s.length, '· 2 funciones parchadas ✓');
