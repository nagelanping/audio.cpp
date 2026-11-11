import { createRequire } from 'node:module';
import path from 'node:path';
import assert from 'node:assert/strict';

const require = createRequire(process.env.UI_BROWSER_TOOLS
  ? path.resolve(process.env.UI_BROWSER_TOOLS, 'package.json') : import.meta.url);
const { chromium } = require('playwright');
const browser = await chromium.launch({ headless: true });
const wav = Buffer.alloc(44 + 1600 * 2);
wav.write('RIFF'); wav.writeUInt32LE(wav.length - 8, 4); wav.write('WAVEfmt ', 8);
wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22);
wav.writeUInt32LE(16000, 24); wav.writeUInt32LE(32000, 28);
wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34);
wav.write('data', 36); wav.writeUInt32LE(wav.length - 44, 40);

try {
  // Separate contexts match the independent model-service lifecycles in llama-swap.
  for (const [family, id, maxTokens] of [
    ['fish_audio', 'fish-s2-pro', '2048'],
    ['fish_drama3', 'Jmica/Drama-3-GGUF', '500'],
  ]) {
    const context = await browser.newContext();
    const page = await context.newPage();
    const requests = [];
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.route('**/health', route => route.fulfill({ json: {
      status: 'ok', backend: 'fixture', models: 1, ui: true, ui_management: false,
    } }));
    await page.route('**/v1/**', route => {
      const url = new URL(route.request().url());
      if (url.pathname === '/v1/models') return route.fulfill({ json: { data: [{
        id, family, task: 'tts', mode: 'streaming', loaded: true, configured: true,
        path: `/fixture/${family}.gguf`, session_options: {},
      }] } });
      if (url.pathname === '/v1/audio/speech') {
        requests.push(route.request().postDataJSON());
        return route.fulfill({ contentType: 'audio/wav', body: wav });
      }
      return route.fulfill({ json: { voices: [] } });
    });
    await page.goto(process.env.UI_BASE_URL || 'http://127.0.0.1:5173');
    await page.waitForFunction(modelId => document.querySelector('#model')?.value === modelId, id);
    assert.equal(await page.locator('#tokens').inputValue(), maxTokens);
    assert.equal(await page.locator('#seed').inputValue(), '-1');
    if (family === 'fish_audio') {
      assert.equal(await page.locator('#chunk-budget').inputValue(), '200');
      assert.equal(await page.locator('#language').inputValue(), '');
      assert.equal(await page.locator('.drama-workspace').count(), 0);
      await page.locator('#text').fill('The library opens at nine. Please return the book tomorrow. '.repeat(8));
      await page.locator('button.run').click();
      await page.locator('.output audio').waitFor();
      await page.waitForFunction(() => !document.querySelector('button.run')?.disabled);
      assert(requests.length > 1, 'S2-Pro must use the displayed 200-character chunk budget');
      assert(requests.every(request => request.max_tokens === 2048 && request.input.length <= 200));
      await page.locator('#tokens').fill('1024');
      await page.locator('#chunk-budget').fill('160');
      assert.equal(await page.locator('#tokens').inputValue(), '1024');
      assert.equal(await page.locator('#chunk-budget').inputValue(), '160');
    } else {
      assert.equal(await page.locator('.drama-workspace').count(), 1);
      assert.equal(await page.locator('#chunk-budget').count(), 0);
    }
    assert.deepEqual(errors, []);
    console.log(`PASS ${family}: defaults, request parameters, and independent UI preserved`);
    await context.close();
  }
} finally {
  await browser.close();
}
