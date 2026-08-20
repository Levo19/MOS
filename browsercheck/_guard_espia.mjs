// [884] guard-espia.html: el equipo se une a la sesión, toma cámara+mic (fake en headless) y SUBE su answer.
// Prueba el lado del dispositivo contra la señalización REAL de Supabase (sin peer master vivo).
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
import { Client } from 'pg';
const ROOT='C:/Users/ISO/ecosistema MOS/ProyectoMOS';
const url=fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim();
const db=new Client({connectionString:url}); await db.connect();
const SES='guardtest_'+Date.now();
// oferta SDP mínima válida para que el device haga setRemoteDescription
const OFERTA=JSON.stringify({type:'offer',sdp:'v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\nc=IN IP4 0.0.0.0\r\na=ice-ufrag:aaaa\r\na=ice-pwd:bbbbbbbbbbbbbbbbbbbbbbbb\r\na=fingerprint:sha-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF\r\na=setup:actpass\r\na=mid:0\r\na=sctp-port:5000\r\n'});
await db.query("insert into mos.espia_sesiones(sesion_id,fecha,master_id,device_id,estado,sdp_oferta) values($1,now(),'test-master','__TEST_GUARD__','PENDIENTE',$2)",[SES,OFERTA]);
const MIME={'.html':'text/html','.js':'text/javascript'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);const f=path.join(ROOT,u);
 if(!fs.existsSync(f)){r.writeHead(404);return r.end('no')} r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'text/plain'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8850,r));
const b=await chromium.launch({args:['--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream']});
const ctx=await b.newContext({permissions:['camera','microphone']}); const p=await ctx.newPage();
const logs=[]; p.on('console',m=>logs.push(m.text()));
await p.goto('http://127.0.0.1:8850/guard-espia.html?secreto=SECRETO_TEST_GUARD_882&sesion='+SES+'&device=__TEST_GUARD__',{waitUntil:'domcontentloaded'});
// esperar hasta que suba el answer (o timeout)
let ans='';
for (let i=0;i<20;i++){ await p.waitForTimeout(1000);
  const r=await db.query("select sdp_respuesta,estado from mos.espia_sesiones where sesion_id=$1",[SES]);
  if (r.rows[0] && r.rows[0].sdp_respuesta){ ans=r.rows[0].sdp_respuesta; var est=r.rows[0].estado; break; } }
const ok=[],bad=[]; const T=(n,c,x)=>{(c?ok:bad).push(n);console.log((c?'  OK  ':'  --  ')+n+(x?'  ·  '+x:''));};
const txt=await p.evaluate(()=>document.getElementById('log').textContent);
console.log('     log:\n'+txt.split('\n').slice(0,8).map(l=>'       '+l).join('\n'));
T('la página mintió el JWT del equipo', /token ok/.test(txt));
T('se unió a la sesión (iniciar_dispositivo ok)', !/iniciar_dispositivo:/.test(txt) || /device __TEST/.test(txt));
T('tomó cámara + micrófono', /media: 1v 1a|media: 1v/.test(txt));
T('SUBIÓ su answer a la señalización real de Supabase', !!ans, ans?('estado='+est+' answer '+ans.length+'b'):'(no subió)');
await b.close(); srv.close();
await db.query("delete from mos.espia_sesiones where sesion_id=$1",[SES]);
await db.query("delete from mos.yape_dispositivos where nombre='__TEST_GUARD__'");
await db.end();
console.log('\n  '+ok.length+' OK   '+bad.length+' fallos'); process.exit(bad.length?1:0);
