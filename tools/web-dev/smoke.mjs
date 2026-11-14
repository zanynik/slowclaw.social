#!/usr/bin/env node
// Clicks through the website in a real browser against the sample-data server.
//
//   npm install --no-save playwright && npx playwright install chromium   (once)
//   node tools/web-dev/smoke.mjs
//
// Exits non-zero when a check fails or the page logs an error. Run it after changing web/.
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const { chromium } = createRequire(import.meta.url)('playwright');
const port = 8700 + Math.floor(Math.random() * 200);
const server = spawn(process.execPath, [fileURLToPath(new URL('./server.mjs', import.meta.url))], { env: { ...process.env, PORT: String(port) } });
await new Promise((resolve, reject) => { server.stdout.once('data', resolve); server.once('error', reject); });

let failed = 0;
const check = (name, ok) => { console.log(ok ? 'ok  ' : 'FAIL', name); if (!ok) failed++; };
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  const items = () => page.locator('.items li');
  const nav = name => page.click(`.nav button:has-text("${name}")`);

  await page.goto(`http://localhost:${port}/`);
  await page.waitForSelector('.journals .title');
  check('pairs and lists journals', (await page.locator('.journals .title').count()) === 4);
  check('page title follows the view', (await page.title()) === 'Journal · SlowClaw');

  await page.keyboard.press('/');
  await page.keyboard.type('health');
  check('"/" searches, space names match', (await page.locator('.journals .title').count()) === 1);
  await page.fill('input.search', '');

  await nav('To-dos');
  await page.fill('[data-add="todo"]', 'First new');
  await page.keyboard.press('Enter');
  await page.waitForSelector('text=First new');
  check('add box keeps the cursor', await page.evaluate(() => document.activeElement?.dataset?.add === 'todo'));

  const before = await items().count();
  await items().filter({ hasText: 'Finish the draft' }).locator('input[type=checkbox]').check();
  await page.waitForFunction(n => document.querySelectorAll('.items li').length === n - 1, before);
  await page.click('#status button:has-text("Undo")');
  await page.waitForFunction(n => document.querySelectorAll('.items li').length === n, before);
  check('checking a to-do can be undone', true);

  await page.locator('.items li span.text', { hasText: 'Buy a rain jacket' }).click();
  await page.keyboard.press('ControlOrMeta+A');
  await page.keyboard.type('Buy a good rain jacket');
  await page.keyboard.press('Enter');
  await page.waitForSelector('text=Buy a good rain jacket');
  check('click a line to edit it', true);

  await items().filter({ hasText: 'First new' }).locator('button[title=Remove]').click();
  await page.waitForFunction(() => !document.body.innerText.includes('First new'));
  await page.click('#status button:has-text("Undo")');
  await page.waitForSelector('text=First new');
  check('removing a line can be undone', true);

  await nav('Work');
  await page.waitForSelector('h1:has-text("Work")');
  check('entries in a space show their day', /Today,/.test(await page.locator('.card .journals li').first().innerText()));

  await page.click('.card .journals li button');
  await page.locator('.editor textarea').press('End');
  await page.keyboard.type(' More.');
  await page.waitForSelector('#status:has-text("Saved")');
  check('editor saves by itself', true);
  await page.click('text=Done');

  // Done pressed right after typing: saved once, and the list (not the editor) is shown.
  await page.waitForSelector('h1:has-text("Journal")');
  await page.keyboard.press('n');
  await page.waitForSelector('.editor textarea');
  await page.keyboard.type('Quick entry');
  await page.click('text=Done');
  await page.waitForSelector('.journals .title:has-text("Quick entry")');
  check('new entry survives a fast Done', (await page.locator('.journals .title:has-text("Quick entry")').count()) === 1
    && (await page.evaluate(() => location.hash)) === '#/');

  for (const [name, selector] of [['Book', '.passage'], ['News', '.news-card'], ['Videos', '.video'], ['Reads', '.reads li']]) {
    await nav(name);
    await page.waitForSelector(selector);
    check(name + ' page', true);
  }

  await page.setViewportSize({ width: 390, height: 780 });
  await page.click('.menu-btn');
  check('phone: menu opens', await page.locator('.side.open').isVisible());
  await page.mouse.click(370, 400);
  check('phone: tapping outside closes it', (await page.locator('.side.open').count()) === 0);
  check('phone: no sideways scroll', await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));

  check('no page errors' + (errors.length ? ': ' + errors.join('; ') : ''), errors.length === 0);
} catch (e) {
  check('ran to the end: ' + e.message.split('\n')[0], false);
} finally {
  await browser.close();
  server.kill();
}
process.exit(failed ? 1 : 0);
