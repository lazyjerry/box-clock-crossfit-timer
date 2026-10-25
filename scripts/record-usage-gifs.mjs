// 以手機尺寸錄下操作流程並轉成 GIF，由 record-usage-gifs.sh 呼叫。
// 用法：node record-usage-gifs.mjs <網址> <輸出目錄> <暫存目錄>；環境變數 PLAYWRIGHT_PREFIX 指向裝了 playwright 的目錄。
import { execFile } from 'node:child_process';
import { mkdir, rm } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { promisify } from 'node:util';

const [baseUrl, outDir, workDir] = process.argv.slice(2);
const require = createRequire(path.join(process.env.PLAYWRIGHT_PREFIX, 'noop.js'));
const { chromium } = require('playwright');
const run = promisify(execFile);

const VIEWPORT = { width: 390, height: 844 };
const GIF_WIDTH = VIEWPORT.width;
const GIF_FPS = 12;

// 點擊位置畫一個淡出的圓圈。用 popover 進 top layer，才不會被 showModal 的對話框蓋住。
function showTaps() {
  addEventListener('pointerdown', (event) => {
    const dot = document.createElement('div');
    dot.popover = 'manual';
    dot.style.cssText = `position:fixed;inset:auto;left:${event.clientX - 22}px;top:${event.clientY - 22}px;width:44px;height:44px;margin:0;padding:0;border:3px solid #fff;border-radius:50%;background:rgba(255,255,255,.35);box-shadow:0 0 0 2px rgba(0,0,0,.35);pointer-events:none;transition:opacity .45s,transform .45s;`;
    document.body.append(dot);
    dot.showPopover();
    setTimeout(() => { dot.style.opacity = '0'; dot.style.transform = 'scale(1.5)'; }, 250);
    setTimeout(() => dot.remove(), 800);
  }, true);
}

// 無頭瀏覽器拿不到 Wake Lock，換成一般手機會拿到的結果，免得錄到「螢幕可能會自動關閉」提醒。
function grantWakeLock() {
  const sentinel = new EventTarget();
  sentinel.release = async () => {};
  Object.defineProperty(navigator, 'wakeLock', { value: { request: async () => sentinel } });
}

const wait = (page, ms) => page.waitForTimeout(ms);

async function reveal(page, selector) {
  const locator = page.locator(selector);
  const moved = await locator.evaluate((node) => {
    const { top, bottom } = node.getBoundingClientRect();
    if (top >= 72 && bottom <= innerHeight - 72) return false;
    node.scrollIntoView({ behavior: 'smooth', block: 'center' });
    return true;
  });
  if (moved) await wait(page, 700);
  return locator;
}

async function tap(page, selector, pause = 700) {
  const locator = await reveal(page, selector);
  await locator.tap();
  await wait(page, pause);
}

async function typeInto(page, selector, text) {
  const locator = await reveal(page, selector);
  await locator.tap();
  await locator.evaluate((node) => node.select?.());
  await locator.pressSequentially(text, { delay: 160 });
  await wait(page, 600);
}

// prepare 在錄影開頭、裁掉之前執行，用來預先調好設定；play 是 GIF 裡看得到的操作。
const SCENES = [
  {
    name: '01-setup',
    async play(page) {
      await wait(page, 600);
      await tap(page, 'label.mode-option:has(input[value="tabata"])', 900);
      await tap(page, '#mode-help-button', 2200);
      await tap(page, '#mode-help-dialog .help-close', 800);
      await tap(page, '#preset-buttons button:has-text("30／15")', 900);
      await typeInto(page, '#tabata-rounds', '4');
      await reveal(page, '#workout-summary');
      await wait(page, 1800);
    }
  },
  {
    name: '02-timer',
    async prepare(page) {
      await page.locator('label.mode-option:has(input[value="tabata"])').tap();
      await page.fill('#tabata-rounds', '2');
      await page.fill('#tabata-work', '3');
      await page.fill('#tabata-rest', '3');
      await page.selectOption('#prep-time', '5');
    },
    async play(page) {
      await tap(page, '.primary-button[type="submit"]', 1000);
      await tap(page, '#start-button', 6500);
      await tap(page, '#start-button', 1500);
      await tap(page, '#start-button', 1800);
      await tap(page, '#reset-button', 1200);
      await tap(page, '#cancel-button', 1500);
    }
  },
  {
    name: '03-share',
    async prepare(page) {
      await page.selectOption('#prep-time', '0');
    },
    async play(page) {
      await tap(page, '.primary-button[type="submit"]', 1000);
      await tap(page, '#start-button', 3200);
      await tap(page, '#finish-button', 1600);
      await tap(page, '#share-button', 700);
      await typeInto(page, '#share-exercise', '波比跳');
      await tap(page, '#share-form .dialog-button', 2200);
      await tap(page, '#copy-text-button', 2000);
    }
  }
];

async function record(browser, scene) {
  const videoDir = path.join(workDir, scene.name);
  const context = await browser.newContext({
    viewport: VIEWPORT,
    deviceScaleFactor: 2,
    isMobile: true,
    hasTouch: true,
    locale: 'zh-TW',
    timezoneId: 'Asia/Taipei',
    serviceWorkers: 'block',
    permissions: ['clipboard-read', 'clipboard-write'],
    // 錄影畫格是 CSS 像素大小，size 設得比 viewport 大只會在右下補灰底，不會變清晰
    recordVideo: { dir: videoDir, size: VIEWPORT }
  });
  await context.addInitScript(showTaps);
  await context.addInitScript(grantWakeLock);
  const page = await context.newPage();
  const openedAt = Date.now();
  await page.goto(baseUrl, { waitUntil: 'networkidle' });
  if (scene.prepare) await scene.prepare(page);
  await page.evaluate(() => scrollTo(0, 0));
  await wait(page, 900);
  const trimSeconds = (Date.now() - openedAt) / 1000;
  await scene.play(page);
  await context.close();
  const video = await page.video().path();
  const gif = path.join(outDir, `${scene.name}.gif`);
  await run('ffmpeg', [
    '-y', '-loglevel', 'error', '-ss', trimSeconds.toFixed(2), '-i', video,
    '-vf', `fps=${GIF_FPS},scale=${GIF_WIDTH}:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle`,
    '-loop', '0', gif
  ]);
  await rm(videoDir, { recursive: true, force: true });
  console.log(`Recorded ${gif}`);
}

await mkdir(outDir, { recursive: true });
const browser = await chromium.launch();
try {
  for (const scene of SCENES) await record(browser, scene);
} finally {
  await browser.close();
}
