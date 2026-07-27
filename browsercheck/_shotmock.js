const {chromium}=require('playwright');
(async()=>{const b=await chromium.launch();const p=await b.newPage({viewport:{width:1120,height:760},deviceScaleFactor:2});
await p.goto('file:///C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/87ed8f2a-b74c-4519-8180-f245e8ec2132/scratchpad/mock_recibo.html');
await p.waitForTimeout(350);
const out=__dirname+'/mock_recibo.png';
await p.screenshot({path:out,fullPage:true});
console.log('=>',out);await b.close();})();
