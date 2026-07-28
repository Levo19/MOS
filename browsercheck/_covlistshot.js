const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const b = await chromium.launch();
  const url = 'file://' + path.resolve('_covlist.html').split(path.sep).join('/');
  const p = await b.newPage({ viewport: { width: 560, height: 460 }, deviceScaleFactor: 2 });
  await p.goto(url); await p.waitForTimeout(300);
  await p.screenshot({ path: '_covlist.png' });
  await b.close(); console.log('OK');
})().catch(e => { console.error(e.message); process.exit(1); });
