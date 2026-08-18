// [849] Los dos clientes tienen que declarar de dónde salió la aprobación. Sin `origen`, el
// servidor no puede distinguir "lo activé yo parado frente al equipo" de "lo aprobé desde el buzón".
import fs from 'fs';
const A = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/assets/';
const da = fs.readFileSync(A + 'auth/device-auth.js', 'utf8');
const sm = fs.readFileSync(A + 'seguridad/seguridad-modal.js', 'utf8');
const ok=[],bad=[]; const T=(n,c,x)=>{(c?ok:bad).push(n);console.log((c?'  ✅ ':'  ❌ ')+n+(x?' — '+x:''));};

// toda llamada a aprobar_dispositivo debe llevar origen
const llamadas = [];
for (const [nom, src] of [['device-auth.js', da], ['seguridad-modal.js', sm]]) {
  const re = /aprobar_dispositivo['"]?\s*,\s*\{([\s\S]{0,420}?)\}/g;
  let m; while ((m = re.exec(src)) !== null) llamadas.push({ nom, cuerpo: m[1], tieneOrigen: /origen\s*:/.test(m[1]),
    valor: (m[1].match(/origen\s*:\s*['"](\w+)['"]/) || [])[1] || '' });
}
console.log('  llamadas a aprobar_dispositivo: ' + llamadas.length);
llamadas.forEach(l => console.log('     ' + l.nom + ' → origen=' + (l.valor || '(FALTA)')));
T('todas las aprobaciones declaran su origen', llamadas.length >= 4 && llamadas.every(l => l.tieneOrigen));
T('la pantalla del equipo bloqueado marca INSITU',
  llamadas.some(l => l.nom === 'device-auth.js' && l.valor === 'INSITU'));
T('el buzón del panel marca PANEL',
  llamadas.filter(l => l.nom === 'seguridad-modal.js' && l.valor === 'PANEL').length >= 3);
T('la aprobación in-situ del modal marca INSITU',
  llamadas.some(l => l.nom === 'seguridad-modal.js' && l.valor === 'INSITU'));
console.log('\n  ' + ok.length + ' ✅   ' + bad.length + ' ❌');
process.exit(bad.length ? 1 : 0);
