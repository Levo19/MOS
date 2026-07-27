const {chromium}=require('playwright');
(async()=>{const b=await chromium.launch();const p=await b.newPage({viewport:{width:1180,height:920},deviceScaleFactor:2});
await p.goto('file:///C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/87ed8f2a-b74c-4519-8180-f245e8ec2132/scratchpad/verif571.html');
await p.waitForTimeout(400);
const out=__dirname+'/verif_571.png';
await p.screenshot({path:out,fullPage:true});
console.log('screenshot =>',out);await b.close();})();
