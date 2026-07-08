const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const b = await chromium.launch({ headless: true });
  const ctx = await b.newContext({ viewport: { width: 720, height: 1300 }, deviceScaleFactor: 2 });
  const pg = await ctx.newPage();
  const url = 'file:///' + path.resolve(__dirname, 'seg_mock.html').split(path.sep).join('/');
  await pg.goto(url, { waitUntil: 'networkidle' });
  await pg.waitForTimeout(500);
  await pg.screenshot({ path: path.resolve(__dirname, 'seg_mock.png'), fullPage: true });
  await b.close();
  console.log('OK seg_mock.png');
})();
