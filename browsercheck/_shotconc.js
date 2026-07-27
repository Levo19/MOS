const {chromium}=require('playwright');
(async()=>{const b=await chromium.launch();const p=await b.newPage({viewport:{width:900,height:560},deviceScaleFactor:2});
await p.goto('file:///C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/87ed8f2a-b74c-4519-8180-f245e8ec2132/scratchpad/mock_conceptos.html');
await p.waitForTimeout(300);
await p.screenshot({path:__dirname+'/mock_conceptos.png',fullPage:true});
console.log('=> mock_conceptos.png');await b.close();})();
