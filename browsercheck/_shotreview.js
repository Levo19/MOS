const {chromium}=require('playwright');
(async()=>{const b=await chromium.launch();const p=await b.newPage({viewport:{width:1160,height:720},deviceScaleFactor:2});
await p.goto('file:///C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/87ed8f2a-b74c-4519-8180-f245e8ec2132/scratchpad/review100x.html');
await p.waitForTimeout(350);
await p.screenshot({path:__dirname+'/review100x.png',fullPage:true});
console.log('=> review100x.png');await b.close();})();
