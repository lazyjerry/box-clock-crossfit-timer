#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$project_dir/src" "$project_dir/public" "$project_dir/tests" "$project_dir/scripts"

cat > "$project_dir/package.json" <<'EOF'
{
  "name": "crossfit-interval-timer",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "node --test tests/*.test.mjs",
    "build": "sh scripts/build.sh",
    "verify": "sh scripts/verify.sh",
    "deploy": "sh scripts/publish.sh"
  }
}
EOF

cat > "$project_dir/src/timer-core.mjs" <<'EOF'
export const MODE_DEFAULTS = Object.freeze({
  amrap: { duration: 12 * 60 },
  emom: { rounds: 10, interval: 60 },
  tabata: { rounds: 8, work: 20, rest: 10 },
  fortime: { cap: 20 * 60 }
});

const clampInteger = (value, min, max, fallback) => {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= min && parsed <= max ? parsed : fallback;
};

export function normalizeConfig(raw = {}) {
  const mode = ['amrap', 'emom', 'tabata', 'fortime'].includes(raw.mode) ? raw.mode : 'amrap';
  const prep = clampInteger(raw.prep, 0, 15, 10);
  if (mode === 'amrap') return { mode, prep, duration: clampInteger(raw.duration, 1, 99 * 60 + 59, MODE_DEFAULTS.amrap.duration) };
  if (mode === 'emom') return {
    mode,
    prep,
    rounds: clampInteger(raw.rounds, 1, 99, MODE_DEFAULTS.emom.rounds),
    interval: clampInteger(raw.interval, 1, 15 * 60, MODE_DEFAULTS.emom.interval)
  };
  if (mode === 'tabata') return {
    mode,
    prep,
    rounds: clampInteger(raw.rounds, 1, 99, MODE_DEFAULTS.tabata.rounds),
    work: clampInteger(raw.work, 1, 15 * 60, MODE_DEFAULTS.tabata.work),
    rest: clampInteger(raw.rest, 0, 15 * 60, MODE_DEFAULTS.tabata.rest)
  };
  return { mode, prep, cap: clampInteger(raw.cap, 1, 99 * 60 + 59, MODE_DEFAULTS.fortime.cap) };
}

export function createPlan(rawConfig) {
  const config = normalizeConfig(rawConfig);
  const phases = [];
  if (config.prep > 0) phases.push({ kind: 'prepare', label: '準備', durationMs: config.prep * 1000, round: 0, totalRounds: 0 });

  if (config.mode === 'amrap') {
    phases.push({ kind: 'work', label: 'AMRAP', durationMs: config.duration * 1000, round: 1, totalRounds: 1 });
  } else if (config.mode === 'emom') {
    for (let round = 1; round <= config.rounds; round += 1) {
      phases.push({ kind: 'work', label: 'EMOM', durationMs: config.interval * 1000, round, totalRounds: config.rounds });
    }
  } else if (config.mode === 'tabata') {
    for (let round = 1; round <= config.rounds; round += 1) {
      phases.push({ kind: 'work', label: '動作', durationMs: config.work * 1000, round, totalRounds: config.rounds });
      if (config.rest > 0 && round < config.rounds) phases.push({ kind: 'rest', label: '休息', durationMs: config.rest * 1000, round, totalRounds: config.rounds });
    }
  } else {
    phases.push({ kind: 'countup', label: 'FOR TIME', durationMs: config.cap * 1000, round: 1, totalRounds: 1 });
  }

  let cursor = 0;
  const timeline = phases.map((phase, index) => {
    const startMs = cursor;
    cursor += phase.durationMs;
    return { ...phase, index, startMs, endMs: cursor };
  });
  return { config, phases: timeline, totalMs: cursor };
}

export function snapshotAt(plan, elapsedMs) {
  const elapsed = Math.max(0, Math.min(elapsedMs, plan.totalMs));
  if (elapsed >= plan.totalMs) {
    const last = plan.phases.at(-1);
    return { complete: true, elapsedMs: plan.totalMs, totalRemainingMs: 0, phase: last, phaseElapsedMs: last.durationMs, phaseRemainingMs: 0 };
  }
  const phase = plan.phases.find((item) => elapsed < item.endMs) ?? plan.phases.at(-1);
  const phaseElapsedMs = elapsed - phase.startMs;
  return {
    complete: false,
    elapsedMs: elapsed,
    totalRemainingMs: plan.totalMs - elapsed,
    phase,
    phaseElapsedMs,
    phaseRemainingMs: phase.durationMs - phaseElapsedMs
  };
}

export function displaySeconds(milliseconds) {
  return Math.max(0, Math.ceil(milliseconds / 1000));
}

export function formatClock(totalSeconds) {
  const seconds = Math.max(0, Math.floor(totalSeconds));
  const minutes = Math.floor(seconds / 60);
  return `${String(minutes).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
}

export function summarizeRun(plan, elapsedMs) {
  const { config } = plan;
  const elapsed = Math.max(0, Math.min(elapsedMs, plan.totalMs));
  const prepMs = plan.phases[0]?.kind === 'prepare' ? plan.phases[0].durationMs : 0;
  const time = formatClock(Math.floor(Math.max(0, elapsed - prepMs) / 1000));
  const rounds = plan.phases.filter((phase) => phase.kind === 'work' && phase.endMs <= elapsed).length;
  if (config.mode === 'tabata') return { label: 'TABATA', time, lines: [`完成 ${rounds}／${config.rounds} 輪`, `動作 ${config.work} 秒／休息 ${config.rest} 秒 · 總時長 ${time}`] };
  if (config.mode === 'emom') return { label: 'EMOM', time, lines: [`完成 ${rounds}／${config.rounds} 輪`, `每輪 ${formatClock(config.interval)} · 總時長 ${time}`] };
  if (config.mode === 'amrap') return { label: 'AMRAP', time, lines: [`固定時間 ${formatClock(config.duration)} 完成`] };
  if (elapsed >= plan.totalMs) return { label: 'FOR TIME', time, lines: [`達到時間上限 ${formatClock(config.cap)}`] };
  return { label: 'FOR TIME', time, lines: [`成績 ${time}`, `時間上限 ${formatClock(config.cap)}`] };
}

export function shareText(summary, exercise) {
  return `我剛做了『${exercise.trim()}』！\n${[summary.label, ...summary.lines].join(' · ')}`;
}

const WARNING_MS = 10000;
const TICK_SECONDS = { prepare: 5, rest: 5, work: 3, countup: 3 };

// True when the shown second has just dropped into the phase's final countdown (5…1 or 3…1).
function countsDown(phase, remainingMs, previousMs) {
  const shown = displaySeconds(remainingMs);
  return shown >= 1 && shown <= TICK_SECONDS[phase.kind] && (previousMs === null || shown < displaySeconds(previousMs));
}

export function cueAt(phase, remainingMs, previous) {
  if (!previous || previous.index !== phase.index) {
    if (phase.kind === 'rest') return 'round-end';
    if (phase.kind !== 'prepare') return 'round-start';
    return countsDown(phase, remainingMs, null) ? 'tick' : null;
  }
  if (countsDown(phase, remainingMs, previous.remainingMs)) return 'tick';
  const warns = (phase.kind === 'work' || phase.kind === 'countup') && phase.durationMs > WARNING_MS;
  return warns && previous.remainingMs > WARNING_MS && remainingMs <= WARNING_MS ? 'warning' : null;
}
EOF

cat > "$project_dir/src/run-state.mjs" <<'EOF'
import { createPlan, normalizeConfig } from './timer-core.mjs';

export function createRunClock(now) {
  let startedAt = 0;
  let pausedAt = 0;
  let pausedTotal = 0;
  let paused = false;

  return {
    start({ elapsedMs = 0, paused: startPaused = false } = {}) {
      startedAt = now() - elapsedMs;
      pausedAt = now();
      pausedTotal = 0;
      paused = startPaused;
    },
    pause() {
      if (paused) return;
      pausedAt = now();
      paused = true;
    },
    resume() {
      if (!paused) return;
      pausedTotal += now() - pausedAt;
      paused = false;
    },
    elapsed() {
      return Math.max(0, (paused ? pausedAt : now()) - startedAt - pausedTotal);
    }
  };
}

export function serializeRun({ config, elapsedMs }) {
  return JSON.stringify({ config, elapsedMs });
}

export function restoreRun(text) {
  let record = null;
  try {
    record = JSON.parse(text);
  } catch {
    return null;
  }
  if (!record || typeof record !== 'object' || !record.config || typeof record.config !== 'object') return null;
  const { elapsedMs } = record;
  if (!Number.isFinite(elapsedMs) || elapsedMs < 0) return null;
  const config = normalizeConfig(record.config);
  if (config.mode !== record.config.mode) return null;
  if (elapsedMs >= createPlan(config).totalMs) return null;
  return { config, elapsedMs };
}

export async function resumeAudio(context) {
  if (!context) return false;
  try {
    await context.resume();
  } catch {
    return false;
  }
  return context.state === 'running';
}

export function formatTimeOfDay(date) {
  return [date.getHours(), date.getMinutes(), date.getSeconds()].map((part) => String(part).padStart(2, '0')).join(':');
}

export function msUntilNextSecond(epochMs) {
  return 1000 - (epochMs % 1000);
}
EOF

cat > "$project_dir/src/device.mjs" <<'EOF'
export function isBatteryLow(battery) {
  return !battery.charging && battery.level < 0.3;
}

export function installButtonAction({ standalone, hasPrompt }) {
  if (standalone) return 'hidden';
  return hasPrompt ? 'prompt' : 'guide';
}

export function installPlatform({ userAgent = '', maxTouchPoints = 0 }) {
  // iPadOS Safari reports a Mac user agent; touch points tell it apart from a real Mac.
  if (/iPhone|iPad|iPod/.test(userAgent) || (/Macintosh/.test(userAgent) && maxTouchPoints > 1)) return 'ios';
  if (/Android/.test(userAgent)) return 'android';
  return 'desktop';
}
EOF

cat > "$project_dir/src/timer-worker.js" <<'EOF'
import { createPlan, snapshotAt } from './timer-core.mjs';
import { createRunClock } from './run-state.mjs';

let plan = null;
let tickHandle = null;
let running = false;
let paused = false;
let runId = 0;

const clock = createRunClock(() => performance.now());

function currentElapsed() {
  return plan ? clock.elapsed() : 0;
}

function emit(type = 'tick') {
  if (!plan) return;
  const snapshot = snapshotAt(plan, currentElapsed());
  self.postMessage({ type: snapshot.complete ? 'complete' : type, snapshot, plan, runId });
  if (snapshot.complete) stopLoop();
}

function startLoop() {
  stopLoop();
  tickHandle = setInterval(() => emit(), 50);
}

function stopLoop() {
  if (tickHandle !== null) clearInterval(tickHandle);
  tickHandle = null;
  if (plan && currentElapsed() >= plan.totalMs) running = false;
}

self.addEventListener('message', ({ data }) => {
  if (data.type === 'start') {
    plan = createPlan(data.config);
    runId = data.runId;
    paused = data.paused === true;
    clock.start({ elapsedMs: data.elapsedMs ?? 0, paused });
    running = true;
    stopLoop();
    emit(paused ? 'paused' : 'started');
    if (!paused) startLoop();
  } else if (data.type === 'pause' && running && !paused) {
    clock.pause();
    paused = true;
    stopLoop();
    emit('paused');
  } else if (data.type === 'resume' && running && paused) {
    clock.resume();
    paused = false;
    emit('resumed');
    startLoop();
  } else if (data.type === 'stop') {
    emit('stopped');
    running = false;
    paused = false;
    stopLoop();
    plan = null;
  } else if (data.type === 'sync' && plan) {
    emit(paused ? 'paused' : 'tick');
  }
});
EOF

cat > "$project_dir/src/index.html" <<'EOF'
<!doctype html>
<html lang="zh-Hant-TW">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="theme-color" content="#171e34">
  <meta name="description" content="支援 AMRAP、EMOM、Tabata 與 For Time 的 CrossFit 離線間歇計時器。">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  <title>BOX CLOCK｜CrossFit 間歇計時器</title>
  <link rel="manifest" href="./manifest.webmanifest">
  <link rel="icon" href="./icon.svg" type="image/svg+xml">
  <link rel="apple-touch-icon" href="./apple-touch-icon.png">
  <link rel="stylesheet" href="./styles.css">
</head>
<body>
  <main id="top">
    <header class="site-header">
      <a class="brand" href="#top" aria-label="BOX CLOCK 首頁"><img class="brand-mark" src="./icon.svg" alt="" width="34" height="34"><span>BOX CLOCK</span></a>
      <div class="status-pills" aria-label="應用程式狀態">
        <span class="status-pill"><i></i>OFFLINE READY</span>
        <button id="install-button" class="install-button" type="button" hidden>安裝 APP</button>
      </div>
    </header>

    <section class="hero" aria-labelledby="page-title">
      <p class="eyebrow">CROSSFIT &amp; SHADOWBOXING INTERVAL TIMER</p>
      <div class="hero-grid">
        <h1 id="page-title"><span>專心訓練</span><em>時間交給我</em></h1>
        <p class="lede">選模式、設時間、按開始。精準校時、離線可用、聲音提示與螢幕常亮都在瀏覽器完成。</p>
      </div>
    </section>

    <section id="setup-view" class="tool-card" aria-labelledby="setup-title">
      <div class="section-heading">
        <span class="section-number">01</span>
        <div><h2 id="setup-title">選擇訓練模式</h2><p>每個模式只顯示必要設定，不用先理解複雜參數。</p></div>
      </div>

      <form id="timer-form" novalidate>
        <fieldset class="mode-picker">
          <legend>訓練模式</legend>
          <div class="mode-grid">
            <label class="mode-option"><input type="radio" name="mode" value="fortime" checked><span><strong>FOR TIME</strong><small>正數計時，完成就停止</small></span></label>
            <label class="mode-option"><input type="radio" name="mode" value="tabata"><span><strong>TABATA</strong><small>動作與休息交替</small></span></label>
            <label class="mode-option"><input type="radio" name="mode" value="emom"><span><strong>EMOM</strong><small>每個間隔開始一輪</small></span></label>
            <label class="mode-option"><input type="radio" name="mode" value="amrap"><span><strong>AMRAP</strong><small>固定時間內完成最多輪</small></span></label>
          </div>
        </fieldset>

        <div class="settings-layout">
          <section class="settings-panel" aria-labelledby="time-settings-title">
            <div class="panel-title"><div class="panel-heading"><span>時間設定</span><button id="mode-help-button" class="help-button" type="button" aria-haspopup="dialog" aria-controls="mode-help-dialog" aria-label="查看 FOR TIME 範例">?</button></div><small id="mode-description">由零開始正數計時；做完按「完成」，或到時間上限自動結束。</small></div>

            <div class="mode-settings" data-mode="amrap" hidden>
              <div class="time-field"><label for="amrap-minutes">訓練時間</label><div><input id="amrap-minutes" name="amrapMinutes" type="number" min="0" max="99" value="12" inputmode="numeric" required><span>分</span><input id="amrap-seconds" name="amrapSeconds" type="number" min="0" max="59" value="0" inputmode="numeric" aria-label="AMRAP 秒數" required><span>秒</span></div></div>
            </div>

            <div class="mode-settings" data-mode="emom" hidden>
              <div class="field-pair">
                <div><label for="emom-rounds">總輪數</label><div class="unit-input"><input id="emom-rounds" name="emomRounds" type="number" min="1" max="99" value="10" inputmode="numeric" required><span>輪</span></div></div>
                <div><label for="emom-interval">每輪間隔</label><div class="unit-input"><input id="emom-interval" name="emomInterval" type="number" min="1" max="900" value="60" inputmode="numeric" required><span>秒</span></div></div>
              </div>
            </div>

            <div class="mode-settings" data-mode="tabata" hidden>
              <div class="field-trio">
                <div><label for="tabata-rounds">總輪數</label><div class="unit-input"><input id="tabata-rounds" name="tabataRounds" type="number" min="1" max="99" value="8" inputmode="numeric" required><span>輪</span></div></div>
                <div><label for="tabata-work">動作</label><div class="unit-input"><input id="tabata-work" name="tabataWork" type="number" min="1" max="900" value="20" inputmode="numeric" required><span>秒</span></div></div>
                <div><label for="tabata-rest">休息</label><div class="unit-input"><input id="tabata-rest" name="tabataRest" type="number" min="0" max="900" value="10" inputmode="numeric" required><span>秒</span></div></div>
              </div>
            </div>

            <div class="mode-settings" data-mode="fortime">
              <div class="time-field"><label for="fortime-minutes">時間上限</label><div><input id="fortime-minutes" name="fortimeMinutes" type="number" min="0" max="99" value="20" inputmode="numeric" required><span>分</span><input id="fortime-seconds" name="fortimeSeconds" type="number" min="0" max="59" value="0" inputmode="numeric" aria-label="For Time 秒數" required><span>秒</span></div></div>
            </div>

            <div class="quick-presets" aria-label="快速套用">
              <span>快速套用</span>
              <div id="preset-buttons"></div>
            </div>
          </section>

          <aside class="start-panel">
            <div class="panel-title"><span>開始前確認</span><small>準備倒數期間也會保持螢幕常亮。</small></div>
            <label for="prep-time">準備倒數</label>
            <select id="prep-time" name="prep">
              <option value="0">直接開始</option>
              <option value="5">5 秒</option>
              <option value="10" selected>10 秒</option>
              <option value="15">15 秒</option>
            </select>
            <div class="sound-settings">
              <div class="sound-copy"><strong>聲音提示</strong><small>拳擊鐘聲：倒數、開始、休息、剩 10 秒、完訓</small></div>
              <div class="sound-controls">
                <label class="sound-switch" for="sound-enabled">
                  <input id="sound-enabled" type="checkbox" checked>
                  <span class="sound-switch-track" aria-hidden="true"><span></span></span>
                  <span id="sound-enabled-label" class="sound-switch-label">開啟</span>
                </label>
                <label class="volume-label" for="sound-volume">音量</label>
                <div class="volume-stepper">
                  <button id="sound-volume-down" type="button" data-volume-step="-1" aria-label="降低提示音量">−</button>
                  <input id="sound-volume" type="number" min="20" max="100" step="5" value="50" inputmode="numeric" aria-describedby="sound-volume-description sound-test-status">
                  <span aria-hidden="true">%</span>
                  <button id="sound-volume-up" type="button" data-volume-step="1" aria-label="提高提示音量">+</button>
                </div>
                <button id="test-sound-button" class="test-sound-button" type="button">試聽</button>
              </div>
              <div class="volume-notes">
                <p class="volume-note"><span id="sound-volume-description">50%：符合裝置音量</span>；<span id="sound-test-status" aria-live="polite">試聽不受開關影響</span></p>
              </div>
            </div>
            <output id="workout-summary" class="workout-summary" aria-live="polite"></output>
            <p id="form-error" class="form-error" role="alert"></p>
            <button class="primary-button" type="submit">開始訓練 <span>→</span></button>
          </aside>
        </div>
      </form>

      <dialog id="mode-help-dialog" class="help-dialog" aria-labelledby="mode-help-title">
        <form method="dialog">
          <div class="help-dialog-head"><h3 id="mode-help-title">FOR TIME 範例</h3><button class="help-close" type="submit" aria-label="關閉">×</button></div>
          <div id="mode-help-body"></div>
        </form>
      </dialog>
    </section>

    <section id="timer-view" class="timer-view" aria-labelledby="timer-phase" hidden>
      <div class="timer-topline"><span id="timer-mode">AMRAP</span><span id="wake-status">螢幕常亮：準備中</span></div>
      <div class="timer-stage" data-phase="prepare">
        <p id="timer-phase" class="timer-phase">準備</p>
        <time id="timer-clock" class="timer-clock" datetime="PT10S">00:10</time>
        <div class="progress-track" aria-hidden="true"><span id="progress-bar"></span></div>
        <p id="round-display" class="round-display">準備開始</p>
        <p id="next-display" class="next-display">接下來 · AMRAP</p>
      </div>
      <div class="timer-controls">
        <button id="finish-button" class="control-button finish" type="button" hidden>完成</button>
        <button id="share-button" class="control-button share" type="button" hidden>分享</button>
        <button id="start-button" class="control-button primary" type="button">開始</button>
        <button id="reset-button" class="control-button" type="button">重置</button>
        <button id="cancel-button" class="control-button ghost" type="button">結束並返回</button>
      </div>
      <p id="timer-live" class="sr-only" aria-live="assertive"></p>
      <dialog id="warning-dialog" class="help-dialog warning-dialog" aria-labelledby="warning-dialog-title">
        <form method="dialog">
          <div class="help-dialog-head"><h3 id="warning-dialog-title">螢幕可能會自動關閉</h3><button class="help-close" type="submit" aria-label="關閉">×</button></div>
          <div id="wake-warning-text">
            <p>無法保持螢幕常亮，計時途中螢幕可能熄滅，也可能聽不到提示音。請試試：</p>
            <ul>
              <li>關閉省電模式（iPhone 的「低耗電模式」）</li>
              <li>把「自動鎖定」或「螢幕逾時」調長</li>
              <li>用最新版 Safari、Chrome 或 Edge，並以 HTTPS 開啟</li>
            </ul>
          </div>
          <p id="battery-warning-text" hidden>電量只剩 <strong id="battery-level"></strong>，訓練途中可能沒電，建議先接上充電器。</p>
          <button class="dialog-button" type="submit">我知道了</button>
        </form>
      </dialog>
      <dialog id="share-dialog" class="help-dialog" aria-labelledby="share-dialog-title">
        <form id="share-form">
          <div class="help-dialog-head"><h3 id="share-dialog-title">分享成績</h3><button class="help-close" type="button" data-close-dialog aria-label="關閉">×</button></div>
          <label for="share-exercise">你剛做什麼運動？</label>
          <input id="share-exercise" class="share-input" type="text" maxlength="30" required autocomplete="off" enterkeyhint="done" placeholder="例如：波比跳">
          <button class="dialog-button" type="submit">馬上分享！</button>
        </form>
      </dialog>
      <dialog id="share-preview-dialog" class="help-dialog" aria-labelledby="share-preview-title">
        <form method="dialog">
          <div class="help-dialog-head"><h3 id="share-preview-title">分享預覽</h3><button class="help-close" type="submit" aria-label="關閉">×</button></div>
          <img id="share-preview-image" class="share-preview" width="1080" height="1080" alt="透明背景的成績浮水印圖片">
          <p id="share-preview-text" class="share-preview-text"></p>
          <div class="share-actions">
            <button id="copy-text-button" class="dialog-button ghost" type="button">複製文字</button>
            <button id="download-image-button" class="dialog-button ghost" type="button">下載浮水印</button>
            <button id="share-image-button" class="dialog-button wide" type="button">分享浮水印</button>
            <button id="share-text-button" class="dialog-button wide" type="button">分享</button>
          </div>
          <p id="share-status" class="share-status" aria-live="polite"></p>
        </form>
      </dialog>
    </section>

    <section class="feature-strip" aria-label="功能說明">
      <article><span>01</span><div><strong>精準校時</strong><p>Web Worker 依實際經過時間重算，不累積計時誤差。</p></div></article>
      <article><span>02</span><div><strong>離線可用</strong><p>安裝 PWA 後，沒有網路也能開啟與訓練。</p></div></article>
      <article><span>03</span><div><strong>保持清醒</strong><p>計時中自動申請 Wake Lock，減少螢幕熄滅。</p></div></article>
    </section>

    <footer><p>BOX&nbsp;CLOCK <span>·</span> LOCAL&nbsp;ONLY <span>·</span> NO&nbsp;ACCOUNT <span>·</span> <span class="footer-end">NO&nbsp;WORKOUT&nbsp;HISTORY<a class="footer-logo" href="#mode-guide-dialog" aria-haspopup="dialog" aria-controls="mode-guide-dialog"><img src="./jerry.png" width="14" height="14" alt="四種訓練模式說明"></a></span></p></footer>

    <dialog id="mode-guide-dialog" class="help-dialog guide-dialog" aria-labelledby="mode-guide-title">
      <form method="dialog">
        <div class="help-dialog-head"><h3 id="mode-guide-title">四種訓練模式</h3><button class="help-close" type="submit" aria-label="關閉">×</button></div>
        <p>差別在「時間怎麼走」與「成績怎麼算」：FOR TIME 份量固定、比快，AMRAP 時間固定、比多；EMOM 與 TABATA 都由計時器切換節奏，EMOM 做得越快休息越久，TABATA 的動作與休息長度固定（經典為 20／10 秒）。</p>
        <dl class="guide-list">
          <dt>FOR TIME<small>份量固定，越快越好</small></dt>
          <dd>做完指定的動作與次數，例如 Fran、Murph。由 00:00 正數，做完按「完成」，成績是完成時間；可設時間上限。</dd>
          <dt>AMRAP<small>時間固定，越多越好</small></dt>
          <dd>As Many Rounds/Reps As Possible。在倒數時間內循環動作，成績是完成輪數加次數，例如 Cindy。</dd>
          <dt>EMOM<small>每個間隔開始一輪</small></dt>
          <dd>Every Minute On the Minute。每個間隔一開始做指定次數，剩下的秒數是休息；適合練技巧與控制配速。</dd>
          <dt>TABATA<small>動作 20 秒、休息 10 秒 × 8 輪</small></dt>
          <dd>約 4 分鐘的高強度間歇，常搭配單一動作。動作與休息自動切換，記下每輪次數，以最少的一輪為成績。</dd>
        </dl>
        <h4>參考資料</h4>
        <ul>
          <li><a href="https://www.crossfit.com/essentials/crossfit-terms-explained" target="_blank" rel="noopener noreferrer">CrossFit Terms Explained</a>：AMRAP、EMOM、Tabata 的定義</li>
          <li><a href="https://www.crossfit.com/essentials/crossfit-intentional-programming" target="_blank" rel="noopener noreferrer">CrossFit：The Four Formats</a>：Couplet、Chipper、間歇、5 Rounds for Time 四種課表格式</li>
          <li><a href="https://pubmed.ncbi.nlm.nih.gov/8897392/" target="_blank" rel="noopener noreferrer">Tabata et al., 1996</a>：20／10 秒間歇的原始研究（單車測功儀，7～8 組至力竭）</li>
          <li><a href="https://www.crossfit.com/benchmark/tabata-this" target="_blank" rel="noopener noreferrer">CrossFit Benchmark：Tabata This!</a>：Tabata 以 8 輪中最少的次數計分</li>
          <li><a href="https://www.hpa.gov.tw/Pages/Detail.aspx?nodeid=825&amp;pid=14209" target="_blank" rel="noopener noreferrer">國民健康署：高強度間歇運動</a>：HIIT 的效果，以及循序漸進、暖身與教練指導等安全提醒</li>
          <li><a href="https://doi.org/10.6162/SRR.2017.140.02" target="_blank" rel="noopener noreferrer">楊美玲、吳柏翰，2017，《大專體育》140 期</a>：CrossFit 訓練內容、效益與運動傷害的文獻回顧</li>
          <li><a href="https://www.mnd.gov.tw/File/42987" target="_blank" rel="noopener noreferrer">國防部：混合健身提升官兵體能之研究</a>：For Time、AMRAP、EMOM 等訓練模式的中文名稱</li>
        </ul>
        <p class="guide-source">原始碼：<a href="https://github.com/lazyjerry/box-clock-crossfit-timer" target="_blank" rel="noopener noreferrer">github.com/lazyjerry/box-clock-crossfit-timer</a></p>
      </form>
    </dialog>

    <svg class="install-defs" width="0" height="0" aria-hidden="true" focusable="false">
      <defs>
        <clipPath id="ip-screen"><rect x="6" y="6" width="78" height="148" rx="9"/></clipPath>
        <symbol id="ip-phone" viewBox="0 0 90 160">
          <rect x="1" y="1" width="88" height="158" rx="13" fill="#171e34"/>
          <rect x="6" y="6" width="78" height="148" rx="9" fill="#f5f3ed"/>
          <rect x="12" y="34" width="9" height="9" rx="2" fill="#171e34"/>
          <rect x="24" y="37" width="24" height="3" fill="#171e34" opacity=".5"/>
          <rect x="12" y="50" width="54" height="7" fill="#171e34"/>
          <rect x="12" y="60" width="42" height="7" fill="none" stroke="#171e34"/>
          <rect x="12" y="74" width="66" height="26" fill="#fffef9" stroke="#d4d2cc"/>
          <rect x="12" y="74" width="66" height="2" fill="#ed735f"/>
          <rect x="35" y="9" width="20" height="5" rx="2.5" fill="#171e34"/>
        </symbol>
        <symbol id="ip-chrome-bar" viewBox="0 0 90 160">
          <rect x="6" y="15" width="78" height="14" fill="#fffef9"/>
          <rect x="10" y="17" width="58" height="10" rx="5" fill="#ecebe5"/>
          <text x="14" y="23.5" font-size="4" fill="#707486" textLength="50" lengthAdjust="spacingAndGlyphs">box-clock.jlab-app.cloud</text>
          <g fill="#171e34"><circle cx="76" cy="18.5" r="1"/><circle cx="76" cy="22" r="1"/><circle cx="76" cy="25.5" r="1"/></g>
        </symbol>
        <symbol id="ip-home" viewBox="0 0 90 160">
          <rect x="1" y="1" width="88" height="158" rx="13" fill="#171e34"/>
          <rect x="6" y="6" width="78" height="148" rx="9" fill="#3b435b"/>
          <g fill="#fff" opacity=".25">
            <rect x="12" y="24" width="13" height="13" rx="3.5"/><rect x="30" y="24" width="13" height="13" rx="3.5"/><rect x="48" y="24" width="13" height="13" rx="3.5"/><rect x="66" y="24" width="13" height="13" rx="3.5"/>
            <rect x="12" y="46" width="13" height="13" rx="3.5"/><rect x="30" y="46" width="13" height="13" rx="3.5"/><rect x="48" y="46" width="13" height="13" rx="3.5"/><rect x="66" y="46" width="13" height="13" rx="3.5"/>
            <rect x="12" y="68" width="13" height="13" rx="3.5"/><rect x="30" y="68" width="13" height="13" rx="3.5"/>
            <rect x="10" y="134" width="70" height="16" rx="6"/>
          </g>
          <image href="./icon.svg" x="48" y="68" width="13" height="13"/>
          <text x="54.5" y="92" font-size="4" font-weight="700" fill="#fff" text-anchor="middle">BOX CLOCK</text>
          <circle cx="54.5" cy="74.5" r="9.5" fill="none" stroke="#ed735f" stroke-width="2"/>
          <rect x="35" y="9" width="20" height="5" rx="2.5" fill="#171e34"/>
        </symbol>
      </defs>
    </svg>

    <dialog id="install-dialog" class="help-dialog install-dialog" aria-labelledby="install-dialog-title">
      <form method="dialog">
        <div class="help-dialog-head"><h3 id="install-dialog-title">加到主畫面</h3><button class="help-close" type="submit" aria-label="關閉">×</button></div>
        <p>加到主畫面後像 App 一樣全螢幕開啟，沒有網路也能訓練。這個瀏覽器沒有一鍵安裝，照下面步驟手動加入。</p>
        <div class="install-tabs" role="group" aria-label="選擇裝置">
          <button type="button" data-install-tab="ios" aria-pressed="false">iPhone／iPad</button>
          <button type="button" data-install-tab="android" aria-pressed="false">Android</button>
          <button type="button" data-install-tab="desktop" aria-pressed="false">電腦</button>
        </div>

        <ol class="install-steps" data-install-panel="ios">
          <li>
            <svg class="install-shot" viewBox="0 0 90 160" aria-hidden="true">
              <use href="#ip-phone" width="90" height="160"/>
              <g clip-path="url(#ip-screen)">
                <rect x="6" y="110" width="78" height="44" fill="#fffef9" stroke="#d4d2cc" stroke-width=".6"/>
                <rect x="12" y="115" width="66" height="11" rx="5.5" fill="#ecebe5"/>
                <text x="19" y="122.3" font-size="4" fill="#707486" textLength="52" lengthAdjust="spacingAndGlyphs">box-clock.jlab-app.cloud</text>
                <g fill="none" stroke="#171e34" stroke-width="1.1" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M19 135l-3 3 3 3"/>
                  <path d="M30 135l3 3-3 3"/>
                  <path d="M42.5 135.5H41v7h8v-7h-1.5M45 138.5v-7M43 133.5l2-2 2 2"/>
                  <path d="M55 135c1.5-.8 3-.8 4.5 0 1.5-.8 3-.8 4.5 0v7c-1.5-.8-3-.8-4.5 0-1.5-.8-3-.8-4.5 0zM59.5 135v7"/>
                  <rect x="69.5" y="135" width="6" height="6" rx="1"/><path d="M71.5 133h5.5v5.5"/>
                </g>
                <circle class="ip-hl" cx="45" cy="137" r="8"/>
              </g>
            </svg>
            <div><strong>點「分享」</strong><p>Safari 點下方工具列的分享鈕（方框加向上箭頭）。iOS 26 先點網址列旁的「⋯」，再點「分享」。</p></div>
          </li>
          <li>
            <svg class="install-shot" viewBox="0 0 90 160" aria-hidden="true">
              <use href="#ip-phone" width="90" height="160"/>
              <g clip-path="url(#ip-screen)">
                <rect x="6" y="6" width="78" height="148" fill="#171e34" opacity=".35"/>
                <rect x="6" y="50" width="78" height="106" rx="7" fill="#f2f2f7"/>
                <rect x="12" y="56" width="66" height="14" rx="3" fill="#fff"/>
                <image href="./icon.svg" x="14" y="58" width="10" height="10"/>
                <text x="27" y="64.8" font-size="5" font-weight="700" fill="#171e34">BOX CLOCK</text>
                <circle cx="18" cy="82" r="5.5" fill="#34c759"/><circle cx="33" cy="82" r="5.5" fill="#5ac8fa"/><circle cx="48" cy="82" r="5.5" fill="#ff9500"/><circle cx="63" cy="82" r="5.5" fill="#8e8e93"/>
                <rect x="12" y="94" width="66" height="52" rx="3" fill="#fff"/>
                <g stroke="#e5e5ea" stroke-width=".6"><path d="M12 107h66M12 120h66M12 133h66"/></g>
                <g font-size="5" fill="#171e34"><text x="16" y="102.3">拷貝</text><text x="16" y="115.3">加入書籤</text><text x="16" y="128.3" font-weight="700">加入主畫面</text><text x="16" y="141.3" fill="#007aff">編輯動作⋯</text></g>
                <g fill="none" stroke="#171e34" stroke-width=".8"><rect x="68" y="123" width="6" height="6" rx="1.2"/><path d="M71 124.5v3M69.5 126h3"/></g>
                <rect class="ip-row" x="12" y="120" width="66" height="13" rx="1"/>
              </g>
            </svg>
            <div><strong>點「加入主畫面」</strong><p>分享選單往下滑就會看到。找不到時點最下方「編輯動作⋯」把它加進清單。</p></div>
          </li>
          <li>
            <svg class="install-shot" viewBox="0 0 90 160" aria-hidden="true">
              <use href="#ip-phone" width="90" height="160"/>
              <g clip-path="url(#ip-screen)">
                <rect x="6" y="6" width="78" height="148" fill="#171e34" opacity=".35"/>
                <rect x="6" y="22" width="78" height="134" rx="7" fill="#f2f2f7"/>
                <text x="12" y="35" font-size="5" fill="#007aff">取消</text>
                <text x="45" y="35" font-size="5" font-weight="700" fill="#171e34" text-anchor="middle">加入主畫面</text>
                <text x="78" y="35" font-size="5.5" font-weight="700" fill="#007aff" text-anchor="end">加入</text>
                <circle class="ip-hl" cx="72.5" cy="33" r="8"/>
                <rect x="12" y="46" width="66" height="22" rx="3" fill="#fff"/>
                <image href="./icon.svg" x="15" y="49" width="16" height="16"/>
                <text x="35" y="56" font-size="5.5" font-weight="700" fill="#171e34">BOX CLOCK</text>
                <rect x="35" y="60" width="34" height="2.5" fill="#c7c7cc"/>
                <rect x="12" y="74" width="66" height="13" rx="3" fill="#fff"/>
                <text x="15" y="82.3" font-size="4.6" fill="#171e34">以網頁 App 開啟</text>
                <rect x="63" y="77" width="12" height="7" rx="3.5" fill="#34c759"/><circle cx="71.5" cy="80.5" r="2.8" fill="#fff"/>
              </g>
            </svg>
            <div><strong>點右上角「加入」</strong><p>保持「以網頁 App 開啟」為開啟，名稱可以自己改。</p></div>
          </li>
          <li>
            <svg class="install-shot" viewBox="0 0 90 160" aria-hidden="true"><use href="#ip-home" width="90" height="160"/></svg>
            <div><strong>從主畫面開啟</strong><p>點 BOX CLOCK 圖示，全螢幕開啟、離線可用，也不會再出現「安裝 APP」按鈕。</p></div>
          </li>
        </ol>

        <ol class="install-steps" data-install-panel="android" hidden>
          <li>
            <svg class="install-shot" viewBox="0 0 90 160" aria-hidden="true">
              <use href="#ip-phone" width="90" height="160"/>
              <use href="#ip-chrome-bar" width="90" height="160"/>
              <circle class="ip-hl" cx="76" cy="22" r="6.5"/>
            </svg>
            <div><strong>點右上角「⋮」</strong><p>Chrome 通常會直接跳出安裝視窗；沒跳出時，從網址列右側的選單手動安裝。</p></div>
          </li>
          <li>
            <svg class="install-shot" viewBox="0 0 90 160" aria-hidden="true">
              <use href="#ip-phone" width="90" height="160"/>
              <use href="#ip-chrome-bar" width="90" height="160"/>
              <rect x="38" y="16" width="46" height="70" rx="3" fill="#171e34" opacity=".12"/>
              <rect x="36" y="14" width="46" height="70" rx="3" fill="#fff" stroke="#d4d2cc" stroke-width=".6"/>
              <g font-size="5" fill="#171e34"><text x="41" y="23.5">新增分頁</text><text x="41" y="34.5">記錄</text><text x="41" y="45.5">書籤</text><text x="41" y="56.5">分享</text><text x="41" y="67.5" font-weight="700">加到主畫面</text><text x="41" y="78.5">設定</text></g>
              <rect class="ip-row" x="36" y="60" width="46" height="11" rx="1"/>
            </svg>
            <div><strong>點「加到主畫面」</strong><p>再選「安裝」。部分版本直接顯示「安裝應用程式」。Samsung 網際網路：「≡」→「新增頁面至」→「主畫面」。</p></div>
          </li>
          <li>
            <svg class="install-shot" viewBox="0 0 90 160" aria-hidden="true">
              <use href="#ip-phone" width="90" height="160"/>
              <g clip-path="url(#ip-screen)">
                <rect x="6" y="6" width="78" height="148" fill="#171e34" opacity=".35"/>
                <rect x="11" y="56" width="68" height="50" rx="5" fill="#fff"/>
                <text x="16" y="66" font-size="5.5" font-weight="700" fill="#171e34">安裝應用程式</text>
                <image href="./icon.svg" x="16" y="71" width="11" height="11"/>
                <text x="31" y="78.3" font-size="5" fill="#171e34">BOX CLOCK</text>
                <text x="51" y="98" font-size="5" fill="#1a73e8" text-anchor="middle">取消</text>
                <text x="68" y="98" font-size="5" font-weight="700" fill="#1a73e8" text-anchor="middle">安裝</text>
                <circle class="ip-hl" cx="68" cy="96.3" r="7"/>
              </g>
            </svg>
            <div><strong>點「安裝」</strong><p>等幾秒，圖示就會出現在主畫面或應用程式清單。</p></div>
          </li>
          <li>
            <svg class="install-shot" viewBox="0 0 90 160" aria-hidden="true"><use href="#ip-home" width="90" height="160"/></svg>
            <div><strong>從主畫面開啟</strong><p>點 BOX CLOCK 圖示，全螢幕開啟、離線可用，也不會再出現「安裝 APP」按鈕。</p></div>
          </li>
        </ol>

        <ul class="install-desktop" data-install-panel="desktop" hidden>
          <li><strong>Chrome／Edge</strong>：點網址列右側的安裝圖示（螢幕加向下箭頭），再按「安裝」。</li>
          <li><strong>Safari（macOS Sonoma 以上）</strong>：選單列「檔案」→「加入 Dock」。</li>
          <li><strong>Firefox</strong>：不支援安裝，加入書籤即可。</li>
        </ul>
      </form>
    </dialog>
  </main>
  <script type="module" src="./app.js"></script>
</body>
</html>
EOF

cat > "$project_dir/src/styles.css" <<'EOF'
[hidden]{display:none!important}
.sound-settings{margin-bottom:22px}.sound-copy strong,.sound-copy small{display:block}.sound-copy strong{color:var(--ink);font-size:13px}.sound-copy small{margin-top:4px;color:var(--muted);font-size:11px}.sound-switch{display:flex;align-items:center;gap:9px;min-height:32px;color:var(--ink);font-size:12px;font-weight:850;cursor:pointer}.sound-switch input{position:absolute;opacity:0;pointer-events:none}.sound-switch-track{width:46px;height:26px;display:block;position:relative;flex:0 0 auto;background:#d4d2cc;border:1px solid #aaa8a1;border-radius:13px;transition:.15s}.sound-switch-track>span{width:20px;height:20px;position:absolute;top:2px;left:2px;background:#fff;border:1px solid #aaa8a1;border-radius:50%;box-shadow:1px 1px 0 rgba(23,30,52,.12);transition:.15s}.sound-switch input:checked+.sound-switch-track{background:var(--purple);border-color:var(--purple)}.sound-switch input:checked+.sound-switch-track>span{transform:translateX(20px);border-color:#fff}.sound-switch input:focus-visible+.sound-switch-track{outline:3px solid rgba(118,82,202,.25);outline-offset:3px}.sound-switch-label{min-width:25px}.sound-controls{display:flex;flex-wrap:wrap;align-items:center;gap:10px;padding-top:12px}.volume-label{margin:0 0 0 auto;color:var(--ink)}.volume-stepper{display:flex;align-items:center;height:40px;background:#fff;border:1px solid #bfc0c4}.volume-stepper button{width:38px;height:100%;padding:0;color:var(--purple);background:transparent;border:0;font-size:18px;font-weight:850;line-height:1}.volume-stepper button:hover:not(:disabled){color:#fff;background:var(--purple)}.volume-stepper button:disabled{opacity:.35;cursor:default}.volume-stepper input[type=number]{width:36px;height:100%;padding:0;border:0;text-align:right;font-size:15px;appearance:textfield;-moz-appearance:textfield}.volume-stepper input::-webkit-inner-spin-button,.volume-stepper input::-webkit-outer-spin-button{margin:0;-webkit-appearance:none}.volume-stepper span{padding:0 4px 0 1px;color:var(--muted);font-size:12px;font-weight:800}.volume-notes{padding:8px 0 16px;border-bottom:1px solid var(--line)}.volume-note{margin:0;color:var(--muted);font-size:11px;line-height:1.45}.test-sound-button{min-height:40px;padding:0 14px;color:var(--purple);background:#fff;border:1px solid color-mix(in srgb,var(--purple) 48%,var(--line));font-size:12px;font-weight:850}.test-sound-button:hover{color:#fff;background:var(--purple)}
:root{color-scheme:light;--paper:#f5f3ed;--card:#fffef9;--ink:#171e34;--muted:#707486;--line:#d4d2cc;--coral:#ed735f;--purple:#7652ca;--green:#398a70;--yellow:#e2a62d;--danger:#c6473a;font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans TC",sans-serif}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;color:var(--ink);background:linear-gradient(rgba(23,30,52,.05) 1px,transparent 1px),linear-gradient(90deg,rgba(23,30,52,.05) 1px,transparent 1px),var(--paper);background-size:24px 24px}button,input,select{font:inherit}button{cursor:pointer}button:focus-visible,input:focus-visible,select:focus-visible{outline:3px solid color-mix(in srgb,var(--coral) 35%,transparent);outline-offset:2px}main{min-height:100vh;padding-bottom:34px}.site-header,.hero,.tool-card,.feature-strip,footer{width:min(1180px,calc(100% - 48px));margin-inline:auto}.site-header{padding:28px 0 8px;display:flex;justify-content:space-between;align-items:center;gap:16px}.brand{display:flex;align-items:center;gap:11px;color:var(--ink);text-decoration:none;font:800 11px/1 ui-monospace,monospace;letter-spacing:.18em}.brand-mark{width:34px;height:34px;display:block}.status-pills{display:flex;align-items:center;gap:10px}.status-pill{display:flex;align-items:center;gap:8px;color:var(--muted);font:800 10px/1 ui-monospace,monospace;letter-spacing:.12em}.status-pill i{width:8px;height:8px;background:var(--green);border-radius:50%}.install-button{padding:8px 10px;color:var(--ink);background:transparent;border:1px solid var(--ink);font:800 10px/1 ui-monospace,monospace;letter-spacing:.08em}.hero{padding:58px 0 44px;border-bottom:3px solid var(--ink)}.eyebrow{margin:0 0 18px;color:var(--coral);font:800 12px/1 ui-monospace,monospace;letter-spacing:.22em}.hero-grid{display:grid;grid-template-columns:1.2fr .8fr;align-items:end;gap:56px}h1{margin:0;font-size:clamp(54px,8vw,102px);line-height:1;letter-spacing:-.065em;font-weight:950}h1 span,h1 em{display:block;font-style:normal}h1 em{color:transparent;-webkit-text-stroke:2px var(--ink);text-shadow:4px 4px 0 rgba(23,30,52,.1)}.lede{margin:0 0 7px;padding:6px 0 6px 22px;border-left:5px solid var(--coral);font-size:16px;font-weight:650;line-height:1.8}.tool-card{margin-top:38px;background:var(--card);border:1px solid var(--line);border-top:7px solid var(--coral);box-shadow:7px 7px 0 rgba(23,30,52,.11)}.section-heading{display:flex;align-items:center;gap:18px;padding:32px}.section-number{width:56px;height:56px;display:grid;place-items:center;flex:0 0 auto;color:#fff;background:var(--coral);border-radius:50%;font:800 14px/1 ui-monospace,monospace}.section-heading h2{margin:0;font-size:clamp(26px,4vw,34px);letter-spacing:-.035em}.section-heading p{margin:6px 0 0;color:var(--muted);font-size:14px}.mode-picker{margin:0;padding:0 32px 32px;border:0}.mode-picker legend{margin-bottom:12px;color:#555a6d;font-size:12px;font-weight:850;letter-spacing:.04em}.mode-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}.mode-option{position:relative;min-width:0}.mode-option input{position:absolute;opacity:0}.mode-option span{height:100%;display:block;padding:18px 16px;background:#f8f7f2;border:1px solid var(--line);transition:.15s}.mode-option strong,.mode-option small{display:block}.mode-option strong{font:900 16px/1 ui-monospace,monospace;letter-spacing:.03em}.mode-option small{margin-top:8px;color:var(--muted);font-size:11px;line-height:1.45}.mode-option input:checked+span{color:#fff;background:var(--ink);border-color:var(--ink);box-shadow:4px 4px 0 var(--coral)}.mode-option input:checked+span small{color:#e4e6ee}.mode-option input:focus-visible+span{outline:3px solid rgba(237,115,95,.3);outline-offset:2px}.settings-layout{display:grid;grid-template-columns:1.15fr .85fr;border-top:1px solid var(--line)}.settings-panel,.start-panel{padding:32px}.settings-panel{background:#faf9f5;border-right:1px solid var(--line)}.start-panel{background:#f1efe8}.panel-title{margin-bottom:26px}.panel-title span,.panel-title small{display:block}.panel-title span{font-size:18px;font-weight:900}.panel-title small{margin-top:6px;color:var(--muted);font-size:12px;line-height:1.5}label{color:#555a6d;font-size:12px;font-weight:800}.time-field>label,.field-pair label,.field-trio label,.start-panel>label{display:block;margin-bottom:9px}.time-field>div{display:grid;grid-template-columns:minmax(0,1fr) auto minmax(0,1fr) auto;align-items:center;gap:10px}.time-field span,.unit-input span{color:var(--muted);font-size:12px;font-weight:800}input[type=number],select{width:100%;height:52px;padding:0 13px;color:var(--ink);background:#fff;border:1px solid #bfc0c4;border-radius:0;font-weight:850;font-variant-numeric:tabular-nums}.field-pair,.field-trio{display:grid;gap:15px}.field-pair{grid-template-columns:1fr 1fr}.field-trio{grid-template-columns:repeat(3,1fr)}.unit-input{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:8px}.quick-presets{margin-top:25px;padding-top:22px;border-top:1px solid var(--line)}.quick-presets>span{display:block;margin-bottom:10px;color:#555a6d;font-size:11px;font-weight:850}.quick-presets>div{display:flex;flex-wrap:wrap;gap:8px}.preset-button{width:auto;min-height:36px;padding:0 13px;color:var(--purple);background:#fff;border:1px solid color-mix(in srgb,var(--purple) 45%,var(--line));font-size:11px;font-weight:850}.preset-button:hover{color:#fff;background:var(--purple)}select{margin-bottom:24px}.toggle-row{display:grid;grid-template-columns:1fr auto;align-items:center;position:relative;margin:0 0 22px;cursor:pointer}.toggle-row strong,.toggle-row small{display:block}.toggle-row strong{color:var(--ink);font-size:13px}.toggle-row small{margin-top:4px;color:var(--muted);font-size:11px}.toggle-row input{position:absolute;opacity:0}.toggle-row i{width:44px;height:24px;position:relative;background:#c9c7c1;border:1px solid #b6b4ae;transition:.15s}.toggle-row i::after{content:"";width:17px;height:17px;position:absolute;top:2px;left:2px;background:#fff;border:1px solid #aaa8a1;transition:.15s}.toggle-row input:checked+i{background:var(--purple);border-color:var(--purple)}.toggle-row input:checked+i::after{transform:translateX(20px);border-color:#fff}.toggle-row input:focus-visible+i{outline:3px solid rgba(118,82,202,.22);outline-offset:2px}.workout-summary{display:block;min-height:72px;margin-bottom:12px;padding:13px 14px;background:#fff;border-left:5px solid var(--purple);font-size:13px;font-weight:750;line-height:1.6}.workout-summary strong{display:block;font-size:17px}.form-error{min-height:19px;margin:0 0 8px;color:var(--danger);font-size:12px;font-weight:750}.primary-button{width:100%;min-height:54px;display:flex;justify-content:space-between;align-items:center;padding:0 18px;color:#fff;background:var(--ink);border:1px solid var(--ink);font-weight:900}.primary-button:hover{background:var(--coral);border-color:var(--coral)}.primary-button span{font-size:20px}.timer-view{min-height:calc(100vh - 32px);margin:16px;background:var(--ink);color:#fff;border:1px solid #3b435b;display:grid;grid-template-rows:auto 1fr auto;overflow:hidden}.timer-view[hidden]{display:none}.timer-topline{display:flex;justify-content:space-between;gap:16px;padding:19px 24px;border-bottom:1px solid #3a4258;color:#bbc1d1;font:800 11px/1 ui-monospace,monospace;letter-spacing:.12em}.timer-stage{display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:0;padding:24px;text-align:center}.timer-phase{margin:0 0 4px;color:var(--coral);font:900 clamp(24px,4vw,48px)/1 ui-monospace,monospace;letter-spacing:.1em}.timer-stage[data-phase=rest] .timer-phase{color:#8b70df}.timer-stage[data-phase=work] .timer-phase,.timer-stage[data-phase=countup] .timer-phase{color:#56b99a}.timer-clock{font:950 clamp(92px,25vw,300px)/.9 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:-.1em;font-variant-numeric:tabular-nums}.progress-track{width:min(680px,86vw);height:9px;margin:34px 0 24px;background:#353e54}.progress-track span{display:block;width:100%;height:100%;background:var(--coral);transform-origin:left center}.timer-stage[data-phase=rest] .progress-track span{background:#8b70df}.timer-stage[data-phase=work] .progress-track span,.timer-stage[data-phase=countup] .progress-track span{background:#56b99a}.round-display{margin:0;font-size:clamp(20px,3vw,36px);font-weight:900}.next-display{margin:9px 0 0;color:#9fa7ba;font-size:13px}.timer-controls{display:flex;justify-content:center;flex-wrap:wrap;gap:10px;padding:19px 20px calc(19px + env(safe-area-inset-bottom));border-top:1px solid #3a4258}.control-button{min-height:48px;padding:0 20px;color:#fff;background:#2b344a;border:1px solid #4a5368;font-weight:850}.control-button.primary{min-width:150px;color:var(--ink);background:#fff;border-color:#fff}.control-button.finish{color:#fff;background:var(--green);border-color:var(--green)}.control-button.ghost{color:#bbc1d1;background:transparent}.control-button:hover{border-color:var(--coral)}.feature-strip{display:grid;grid-template-columns:repeat(3,1fr);margin-top:34px;background:rgba(255,254,249,.86);border:1px solid var(--line)}.feature-strip article{display:flex;gap:14px;padding:22px}.feature-strip article+article{border-left:1px solid var(--line)}.feature-strip article>span{color:var(--coral);font:900 11px/1 ui-monospace,monospace}.feature-strip strong{font-size:13px}.feature-strip p{margin:5px 0 0;color:var(--muted);font-size:11px;line-height:1.55}footer{margin-top:28px;padding:22px 0 0;color:var(--muted);border-top:2px solid var(--ink);font:10px/1.5 ui-monospace,monospace;letter-spacing:.08em;text-align:center}footer span{padding:0 8px}footer p{margin:0;text-wrap:balance}footer .footer-end{display:inline-flex;align-items:center;gap:10px;padding:0;white-space:nowrap}.footer-logo{display:block;flex:0 0 auto;border-radius:50%;line-height:0}.footer-logo img{width:14px;height:14px;display:block;transition:transform .15s}.footer-logo:hover img{transform:scale(1.15)}.guide-list{margin:14px 0 16px}.guide-list dt{margin-top:12px;font:900 14px/1.3 ui-monospace,monospace;letter-spacing:.03em}.guide-list dt:first-child{margin-top:0}.guide-list dt small{display:block;margin-top:3px;color:var(--coral);font-size:12px;letter-spacing:0}.guide-list dd{margin:5px 0 0;padding-left:12px;color:#4a4f62;border-left:3px solid var(--line);font-size:13px;line-height:1.7}.guide-dialog h4{margin:0 0 6px;font-size:13px;font-weight:900}.guide-dialog a{color:var(--purple)}.guide-dialog .guide-source{padding-top:12px;border-top:1px solid var(--line)}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}body.timer-running{overflow:hidden}
.panel-heading{display:flex;align-items:center;gap:10px}.panel-heading span{line-height:24px}.help-button{width:24px;height:24px;flex:0 0 auto;display:grid;place-items:center;padding:0;color:var(--purple);background:#fff;border:1px solid color-mix(in srgb,var(--purple) 48%,var(--line));border-radius:50%;font:900 12px/1 ui-monospace,monospace}.help-button:hover{color:#fff;background:var(--purple)}.help-dialog{width:min(440px,calc(100% - 32px));padding:0;color:var(--ink);background:var(--card);border:1px solid var(--line);border-top:7px solid var(--purple);box-shadow:7px 7px 0 rgba(23,30,52,.18)}.help-dialog::backdrop{background:rgba(23,30,52,.45)}.help-dialog form{padding:22px 24px 24px}.help-dialog-head{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:14px}.help-dialog h3{margin:0;font-size:18px;font-weight:900}.help-close{width:34px;height:34px;padding:0;color:var(--ink);background:transparent;border:1px solid var(--line);font-size:18px;line-height:1}.help-close:hover{border-color:var(--purple)}.help-dialog p{margin:0;color:#4a4f62;font-size:13px;line-height:1.7}.help-dialog .help-setting{margin-bottom:12px;padding:10px 12px;color:var(--ink);background:#fff;border-left:5px solid var(--purple);font-weight:800}.help-dialog ul{margin:0 0 12px;padding-left:20px;font-size:13px;font-weight:750;line-height:1.8}
body.timer-running{background:var(--ink)}body.timer-running main{min-height:0;padding-bottom:0}body.timer-running .timer-view{height:100vh;height:100dvh;min-height:0;margin:0;border:0}
.timer-controls{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));padding-inline:max(12px,calc((100% - 560px)/2))}#timer-view .control-button{min-width:0;padding-inline:10px;white-space:nowrap}.timer-controls .finish{grid-column:1/-1}@media(max-width:360px){#timer-view .control-button{padding-inline:6px;font-size:14px}}@media(orientation:landscape) and (max-height:620px){.timer-stage .timer-clock{font-size:min(24vh,160px)}}
.timer-controls .share{grid-column:1/-1}.control-button.share{color:#fff;background:var(--coral);border-color:var(--coral)}.timer-stage[data-phase=done] .timer-phase{color:#56b99a}.timer-stage[data-phase=done] .progress-track span{background:#56b99a}#wake-status{font-variant-numeric:tabular-nums}#wake-status.wake-warning{margin:-4px -8px;padding:4px 8px;color:#fff;background:#ff2d55;box-shadow:0 0 14px rgba(255,45,85,.7)}.warning-dialog{border-top-color:#ff2d55}.dialog-button{width:100%;min-height:46px;margin-top:16px;color:#fff;background:var(--ink);border:1px solid var(--ink);font-weight:900}.dialog-button:hover{background:var(--coral);border-color:var(--coral)}.dialog-button.ghost{color:var(--ink);background:transparent}.dialog-button.ghost:hover{color:#fff;background:var(--coral)}.help-dialog label{display:block;color:var(--ink);font-size:14px}.share-input{width:100%;height:50px;margin-top:9px;padding:0 13px;color:var(--ink);background:#fff;border:1px solid #bfc0c4;border-radius:0;font-size:16px;font-weight:800}.share-preview{display:block;width:100%;height:auto;background:repeating-conic-gradient(#d8d6cf 0 25%,#f3f1ea 0 50%) 0 0/24px 24px;border:1px solid var(--line)}.help-dialog .share-preview-text{margin-top:12px;color:var(--ink);font-weight:800;white-space:pre-line}.share-actions{display:grid;grid-template-columns:1fr 1fr;gap:8px}.share-actions .dialog-button{margin-top:12px}.share-actions .wide{grid-column:1/-1;margin-top:0}.help-dialog .share-status{min-height:22px;margin-top:8px;color:var(--green);font-weight:800}
.install-defs{position:absolute;width:0;height:0;overflow:hidden}.install-dialog{width:min(500px,calc(100% - 24px))}.install-tabs{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));margin:16px 0 4px;border:1px solid var(--ink)}.install-tabs button{min-height:38px;padding:0 6px;color:var(--ink);background:transparent;border:0;font-size:12px;font-weight:850}.install-tabs button+button{border-left:1px solid var(--ink)}.install-tabs button[aria-pressed=true]{color:#fff;background:var(--ink)}.install-steps{margin:0;padding:0;list-style:none;counter-reset:install-step}.install-steps li{display:grid;grid-template-columns:84px minmax(0,1fr);align-items:center;gap:16px;padding:14px 0;border-bottom:1px solid var(--line);counter-increment:install-step}.install-steps li:last-child{border-bottom:0;padding-bottom:0}.install-shot{width:84px;height:auto;display:block;font-family:inherit}.install-shot .ip-hl{fill:none;stroke:var(--coral);stroke-width:2}.install-shot .ip-row{fill:color-mix(in srgb,var(--coral) 18%,transparent);stroke:var(--coral);stroke-width:1.2}.install-steps strong{display:block;margin-bottom:4px;font-size:15px;font-weight:900}.install-steps strong::before{content:counter(install-step);display:inline-grid;place-items:center;width:20px;height:20px;margin-right:8px;color:#fff;background:var(--coral);border-radius:50%;font:900 11px/1 ui-monospace,monospace;vertical-align:2px}.help-dialog .install-desktop{margin:14px 0 0;color:#4a4f62;font-weight:500}.install-desktop strong{color:var(--ink)}.install-desktop li+li{margin-top:6px}
@media(max-width:800px){.site-header,.hero,.tool-card,.feature-strip,footer{width:calc(100% - 32px)}.hero{padding:42px 0 32px}.hero-grid{grid-template-columns:1fr;gap:30px}.lede{padding:6px 22px 6px 0;border-left:0;border-right:5px solid var(--coral);font-size:14px;text-align:right}.section-heading{padding:25px 20px}.mode-picker{padding:0 20px 24px}.mode-grid{grid-template-columns:1fr 1fr}.settings-layout{grid-template-columns:1fr}.settings-panel{border-right:0;border-bottom:1px solid var(--line)}.settings-panel,.start-panel{padding:24px 20px}.feature-strip{grid-template-columns:1fr}.feature-strip article+article{border-left:0;border-top:1px solid var(--line)}.timer-clock{font-size:clamp(80px,25vw,170px)}}
@media(max-width:480px){.site-header{padding:12px 0 0}.status-pill{font-size:0}.status-pill i{width:9px;height:9px}.hero{padding:16px 0 18px}.eyebrow{margin-bottom:10px;font-size:10px}.hero-grid{gap:12px}h1{font-size:36px}h1 em{-webkit-text-stroke-width:1.5px;text-shadow:3px 3px 0 rgba(23,30,52,.1)}.lede{margin:0;padding:3px 16px 3px 0;border-right-width:4px;font-size:13px;line-height:1.6}.mode-grid{grid-template-columns:1fr}.mode-option span{padding:14px}.field-trio{grid-template-columns:1fr 1fr}.field-trio>div:last-child{grid-column:1/-1}.timer-view{min-height:100dvh;margin:0;border:0}.timer-topline{padding:15px 16px}.timer-stage{padding:16px}.timer-clock{font-size:clamp(72px,26vw,124px)}.timer-controls{padding-inline:12px}.control-button{padding-inline:14px}.control-button.primary{min-width:120px}}
@media(max-width:480px){.sound-controls{gap:6px}.volume-label{position:absolute;width:1px;height:1px;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap}.volume-stepper{margin-left:auto}.volume-stepper button{width:30px}.volume-stepper input[type=number]{width:32px}.test-sound-button{padding:0 10px}}
@media(max-width:340px){.sound-controls{gap:4px}.volume-stepper button{width:28px}.volume-stepper span{padding-right:2px}}
@media(orientation:landscape) and (max-height:620px){.timer-stage{padding:10px}.timer-phase{font-size:22px}.timer-clock{font-size:min(34vh,180px)}.progress-track{margin:14px 0 12px}.round-display{font-size:20px}.next-display{margin-top:4px}.timer-controls{padding-top:10px;padding-bottom:calc(10px + env(safe-area-inset-bottom))}.control-button{min-height:42px}}
@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important;transition:none!important}}
.help-dialog[open]{display:flex;flex-direction:column;max-height:calc(100vh - 32px);max-height:calc(100dvh - 32px - env(safe-area-inset-top) - env(safe-area-inset-bottom));overflow:hidden}.help-dialog form{min-height:0;overflow-y:auto;overscroll-behavior:contain;-webkit-overflow-scrolling:touch}
EOF

cat > "$project_dir/src/app.js" <<'EOF'
import { createPlan, cueAt, displaySeconds, formatClock, shareText, snapshotAt, summarizeRun } from './timer-core.mjs';
import { formatTimeOfDay, msUntilNextSecond, restoreRun, resumeAudio, serializeRun } from './run-state.mjs';
import { installButtonAction, installPlatform, isBatteryLow } from './device.mjs';

const $ =(selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const form = $('#timer-form');
const setupView = $('#setup-view');
const timerView = $('#timer-view');
const timerStage = $('.timer-stage');
const worker = new Worker('./timer-worker.js', { type: 'module' });

const MODE_META = {
  amrap: {
    label: 'AMRAP',
    description: '固定倒數，在時間內完成最多輪數或次數。',
    example: {
      setting: '訓練時間 20 分鐘（經典 Cindy）',
      workout: ['引體向上 5 下', '伏地挺身 10 下', '空氣深蹲 15 下'],
      how: '依序做完三個動作算一輪，循環到時間結束；記錄完成輪數加最後一輪的次數，例如 15 輪＋8 下。'
    }
  },
  emom: {
    label: 'EMOM',
    description: '每個間隔開始新一輪，剩餘時間就是該輪休息。',
    example: {
      setting: '總輪數 10 輪 · 每輪間隔 60 秒（共 10 分鐘）',
      workout: ['每分鐘一開始：壺鈴擺盪 15 下', '做完後剩下的秒數就是休息'],
      how: '每 60 秒自動進入下一輪並響提示音；如果 60 秒內做不完，下一輪就減少次數或降低重量。'
    }
  },
  tabata: {
    label: 'TABATA',
    description: '動作與休息交替，預設為經典 20／10 秒 × 8 輪。',
    example: {
      setting: '總輪數 8 輪 · 動作 20 秒／休息 10 秒（約 4 分鐘）',
      workout: ['動作：空氣深蹲', '每輪 20 秒內做越多下越好'],
      how: '計時器自動在動作與休息之間切換並響提示音；記下每輪次數，以最少的一輪作為成績。'
    }
  },
  fortime: {
    label: 'FOR TIME',
    description: '由零開始正數計時；做完按「完成」，或到時間上限自動結束。',
    example: {
      setting: '時間上限 10 分鐘（經典 Fran）',
      workout: ['第 1 回合：火箭推 21 下＋引體向上 21 下', '第 2 回合：各 15 下', '第 3 回合：各 9 下'],
      how: '按開始後由 00:00 正數計時，全部做完立刻按「完成」，畫面上的時間就是成績；10 分鐘到會自動結束。'
    }
  }
};

const STORAGE_KEY = 'box-clock-settings';
const RUN_STORAGE_KEY = 'box-clock-run';
const SHARED_FIELDS = '.start-panel input, .start-panel select, #share-exercise';
const MODE_FIELDS = 'input, select';

const PRESETS = {
  amrap: [
    { label: '8 分鐘', values: { amrapMinutes: 8, amrapSeconds: 0 } },
    { label: '12 分鐘', values: { amrapMinutes: 12, amrapSeconds: 0 } },
    { label: '20 分鐘', values: { amrapMinutes: 20, amrapSeconds: 0 } }
  ],
  emom: [
    { label: '10 × 1 分', values: { emomRounds: 10, emomInterval: 60 } },
    { label: '12 × 1 分', values: { emomRounds: 12, emomInterval: 60 } },
    { label: '10 × 2 分', values: { emomRounds: 10, emomInterval: 120 } }
  ],
  tabata: [
    { label: '經典 20／10 × 8', values: { tabataRounds: 8, tabataWork: 20, tabataRest: 10 } },
    { label: '30／15 × 8', values: { tabataRounds: 8, tabataWork: 30, tabataRest: 15 } },
    { label: '40／20 × 6', values: { tabataRounds: 6, tabataWork: 40, tabataRest: 20 } }
  ],
  fortime: [
    { label: '上限 2 分', values: { fortimeMinutes: 2, fortimeSeconds: 0 } },
    { label: '上限 3 分', values: { fortimeMinutes: 3, fortimeSeconds: 0 } },
    { label: '上限 10 分', values: { fortimeMinutes: 10, fortimeSeconds: 0 } },
    { label: '上限 20 分', values: { fortimeMinutes: 20, fortimeSeconds: 0 } },
    { label: '上限 30 分', values: { fortimeMinutes: 30, fortimeSeconds: 0 } }
  ]
};

let audioContext = null;
let audioOutput = null;
let wakeLock = null;
let currentPlan = null;
let currentConfig = null;
let currentSnapshot = null;
let currentMode = 'fortime';
let isPaused = false;
let isRunning = false;
let isFinished = false;
let runId = 0;
let soundEnabled = true;
let soundVolume = 0.5;
let previousPhaseIndex = -1;
let lastCue = null;
let noiseBuffer = null;
let installPrompt = null;
let wakeStatus = { text: '螢幕常亮：準備中', failed: false };
let wakeWarned = false;
let wallClockHandle = null;
let wallClockActive = false;
let currentSummary = null;
let shareContent = null;

function numberValue(name) {
  return Number(form.elements[name].value);
}

function readConfig() {
  const mode = form.elements.mode.value;
  const prep = numberValue('prep');
  if (mode === 'amrap') return { mode, prep, duration: numberValue('amrapMinutes') * 60 + numberValue('amrapSeconds') };
  if (mode === 'emom') return { mode, prep, rounds: numberValue('emomRounds'), interval: numberValue('emomInterval') };
  if (mode === 'tabata') return { mode, prep, rounds: numberValue('tabataRounds'), work: numberValue('tabataWork'), rest: numberValue('tabataRest') };
  return { mode, prep, cap: numberValue('fortimeMinutes') * 60 + numberValue('fortimeSeconds') };
}

function validateConfig(config) {
  const invalidField = $$('[data-mode]:not([hidden]) input').find((input) => !input.checkValidity());
  if (invalidField) {
    invalidField.focus();
    return invalidField.validationMessage || '請檢查時間設定。';
  }
  return durationError(config);
}

function durationError(config) {
  if (config.mode === 'amrap' && config.duration < 1) return '訓練時間至少 1 秒。';
  if (config.mode === 'fortime' && config.cap < 1) return '時間上限至少 1 秒。';
  return '';
}

function summaryText(config) {
  const fieldsValid = $$('[data-mode]:not([hidden]) input').every((input) => input.checkValidity());
  const issue = fieldsValid ? durationError(config) : '請檢查時間設定。';
  if (issue) return `<strong>${MODE_META[config.mode].label} · 時間未設定完成</strong>${issue}`;
  const prep = config.prep ? ` · 準備 ${config.prep} 秒` : ' · 直接開始';
  if (config.mode === 'amrap') return `<strong>AMRAP · ${formatClock(config.duration)}</strong>固定時間倒數${prep}`;
  if (config.mode === 'emom') return `<strong>EMOM · ${config.rounds} 輪</strong>每輪 ${formatClock(config.interval)}${prep}`;
  if (config.mode === 'tabata') return `<strong>TABATA · ${config.rounds} 輪</strong>動作 ${config.work} 秒／休息 ${config.rest} 秒${prep}`;
  return `<strong>FOR TIME · 上限 ${formatClock(config.cap)}</strong>由 00:00 正數計時${prep}`;
}

function updateSetup() {
  currentMode = form.elements.mode.value;
  $$('[data-mode]').forEach((panel) => { panel.hidden = panel.dataset.mode !== currentMode; });
  $('#mode-description').textContent = MODE_META[currentMode].description;
  $('#mode-help-button').setAttribute('aria-label', `查看 ${MODE_META[currentMode].label} 範例`);
  const presetContainer = $('#preset-buttons');
  presetContainer.replaceChildren(...PRESETS[currentMode].map((preset) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'preset-button';
    button.textContent = preset.label;
    button.addEventListener('click', () => {
      Object.entries(preset.values).forEach(([name, value]) => { form.elements[name].value = value; });
      updateSummary();
      saveSettings();
    });
    return button;
  }));
  updateSummary();
}

function updateSummary() {
  const config = readConfig();
  $('#workout-summary').innerHTML = summaryText(config);
  $('#form-error').textContent = '';
}

function collectFields(fields) {
  return Object.fromEntries(fields.map((field) => [field.id, field.type === 'checkbox' ? field.checked : field.value]));
}

function saveSettings() {
  const settings = { shared: collectFields($$(SHARED_FIELDS)), modes: {} };
  $$('[data-mode]').forEach((panel) => { settings.modes[panel.dataset.mode] = collectFields($$(MODE_FIELDS, panel)); });
  settings.mode = form.elements.mode.value;
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(settings));
  } catch {}
}

function restoreFields(fields, values) {
  if (!values || typeof values !== 'object') return;
  fields.forEach((field) => {
    if (!(field.id in values)) return;
    if (field.type === 'checkbox') {
      field.checked = values[field.id] === true;
      return;
    }
    const stored = String(values[field.id]);
    field.value = stored;
    if (field.tagName === 'SELECT') {
      if (field.selectedIndex < 0) field.value = $('option[selected]', field).value;
    } else if (field.value !== stored || !field.checkValidity()) field.value = field.defaultValue;
  });
}

function loadSettings() {
  let settings = null;
  try {
    settings = JSON.parse(localStorage.getItem(STORAGE_KEY));
  } catch {}
  if (!settings || typeof settings !== 'object') return;
  restoreFields($$(SHARED_FIELDS), settings.shared);
  $$('[data-mode]').forEach((panel) => restoreFields($$(MODE_FIELDS, panel), settings.modes?.[panel.dataset.mode]));
  // 不在選項內的值不會勾到任何 radio，維持 HTML 預設勾選
  if (typeof settings.mode === 'string') form.elements.mode.value = settings.mode;
}

function openModeHelp() {
  const { label, example } = MODE_META[currentMode];
  const setting = document.createElement('p');
  setting.className = 'help-setting';
  setting.textContent = `計時設定：${example.setting}`;
  const workout = document.createElement('ul');
  workout.replaceChildren(...example.workout.map((item) => {
    const line = document.createElement('li');
    line.textContent = item;
    return line;
  }));
  const how = document.createElement('p');
  how.textContent = example.how;
  $('#mode-help-title').textContent = `${label} 範例`;
  $('#mode-help-body').replaceChildren(setting, workout, how);
  $('#mode-help-dialog').showModal();
}

async function unlockAudio() {
  if (!audioContext) {
    audioContext = new AudioContext();
    audioOutput = audioContext.createGain();
    const compressor = audioContext.createDynamicsCompressor();
    compressor.threshold.value = -10;
    compressor.knee.value = 18;
    compressor.ratio.value = 12;
    compressor.attack.value = 0.003;
    compressor.release.value = 0.25;
    audioOutput.connect(compressor).connect(audioContext.destination);
    applySoundVolume();
  }
  return resumeAudio(audioContext);
}

function soundOutputGain() {
  return soundVolume * 2;
}

function applySoundVolume() {
  if (!audioContext || !audioOutput) return;
  audioOutput.gain.setTargetAtTime(soundOutputGain(), audioContext.currentTime, 0.01);
}

// Boxing bell: inharmonic partials with a fast strike and a long ring; [ratio, gain, decay seconds].
const BELL_HZ = 880;
const BELL_PARTIALS = [[0.5, 0.06, 1.8], [1, 0.26, 1.5], [2.76, 0.12, 0.8], [5.4, 0.06, 0.4], [8.93, 0.03, 0.2]];

function canPlay(force) {
  return (soundEnabled || force) && audioContext !== null;
}

function ring(frequency, start, gain, decay, type = 'sine') {
  const oscillator = audioContext.createOscillator();
  const volume = audioContext.createGain();
  oscillator.type = type;
  oscillator.frequency.setValueAtTime(frequency, start);
  volume.gain.setValueAtTime(0.0001, start);
  volume.gain.exponentialRampToValueAtTime(gain, start + 0.004);
  volume.gain.exponentialRampToValueAtTime(0.0001, start + decay);
  oscillator.connect(volume).connect(audioOutput);
  oscillator.start(start);
  oscillator.stop(start + decay + 0.02);
}

function knock(start, gain, frequency, decay) {
  if (!noiseBuffer) {
    noiseBuffer = audioContext.createBuffer(1, Math.round(audioContext.sampleRate * 0.2), audioContext.sampleRate);
    const samples = noiseBuffer.getChannelData(0);
    for (let i = 0; i < samples.length; i += 1) samples[i] = Math.random() * 2 - 1;
  }
  const source = audioContext.createBufferSource();
  const filter = audioContext.createBiquadFilter();
  const volume = audioContext.createGain();
  source.buffer = noiseBuffer;
  filter.type = 'bandpass';
  filter.frequency.setValueAtTime(frequency, start);
  filter.Q.setValueAtTime(3, start);
  volume.gain.setValueAtTime(gain, start);
  volume.gain.exponentialRampToValueAtTime(0.0001, start + decay);
  source.connect(filter).connect(volume).connect(audioOutput);
  source.start(start);
  source.stop(start + decay + 0.02);
}

function strikeBell(delay, strength, sustain) {
  const start = audioContext.currentTime + delay;
  knock(start, 0.18 * strength, 3000, 0.03);
  for (const [ratio, gain, decay] of BELL_PARTIALS) ring(BELL_HZ * ratio, start, gain * strength, decay * sustain);
}

function playBell(times, { spacing = 0.3, strength = 1, sustain = 1, force = false } = {}) {
  if (!canPlay(force)) return;
  for (let hit = 0; hit < times; hit += 1) strikeBell(hit * spacing, strength, sustain);
}

function woodHit(start) {
  knock(start, 0.5, 1600, 0.06);
  ring(620, start, 0.1, 0.05, 'triangle');
}

function playClapper() {
  if (!canPlay(false)) return;
  for (const delay of [0, 0.14, 0.28]) woodHit(audioContext.currentTime + delay);
}

function playTick() {
  if (!canPlay(false)) return;
  woodHit(audioContext.currentTime);
}

function playCue(cue) {
  if (cue === 'round-start') playBell(1);
  else if (cue === 'round-end') playBell(3);
  else if (cue === 'warning') playClapper();
  else if (cue === 'tick') playTick();
}

function playComplete() {
  playBell(3, { spacing: 0.42, strength: 1.25, sustain: 1.6 });
}

function playSoundPreview() {
  playBell(3, { force: true });
}

function normalizeSoundVolume() {
  const field = $('#sound-volume');
  const value = Number(field.value);
  const step = Number(field.step);
  field.value = field.value === '' || !Number.isFinite(value)
    ? field.defaultValue
    : Math.min(Number(field.max), Math.max(Number(field.min), Math.round(value / step) * step));
}

function updateSoundVolume() {
  const field = $('#sound-volume');
  if (field.value === '' || !field.checkValidity()) return;
  soundVolume = Number(field.value) / 100;
  applySoundVolume();
  $('#sound-volume-down').disabled = Number(field.value) <= Number(field.min);
  $('#sound-volume-up').disabled = Number(field.value) >= Number(field.max);
  const percent = Math.round(soundVolume * 100);
  const changeDb = Math.round(20 * Math.log10(soundOutputGain()) * 10) / 10;
  $('#sound-volume-description').textContent = percent === 50
    ? '50%：符合裝置音量'
    : percent < 50
      ? `${percent}%：低於裝置音量`
      : `${percent}%：+${changeDb} dB，上限由系統控制`;
}

function updateSoundToggleLabel() {
  const enabled = $('#sound-enabled').checked;
  $('#sound-enabled-label').textContent = enabled ? '開啟' : '關閉';
}

async function requestWakeLock() {
  if (!('wakeLock' in navigator)) {
    setWakeStatus('螢幕常亮：此瀏覽器不支援', true);
    return;
  }
  try {
    wakeLock = await navigator.wakeLock.request('screen');
    setWakeStatus('螢幕常亮：已啟用');
    wakeLock.addEventListener('release', () => {
      wakeLock = null;
      if (!timerView.hidden && document.visibilityState === 'visible') setWakeStatus('螢幕常亮：已釋放');
    });
  } catch {
    setWakeStatus('螢幕常亮：無法啟用', true);
  }
}

function setWakeStatus(text, failed = false) {
  wakeStatus = { text, failed };
  if (!wallClockActive) renderWakeStatus();
}

function renderWakeStatus() {
  $('#wake-status').textContent = wakeStatus.text;
  $('#wake-status').classList.toggle('wake-warning', wakeStatus.failed);
}

function tickWallClock() {
  const now = Date.now();
  $('#wake-status').textContent = formatTimeOfDay(new Date(now));
  clearTimeout(wallClockHandle);
  wallClockHandle = setTimeout(tickWallClock, msUntilNextSecond(now));
}

function startWallClock() {
  if (wallClockActive) return;
  wallClockActive = true;
  $('#wake-status').classList.remove('wake-warning');
  tickWallClock();
}

function suspendWallClock() {
  clearTimeout(wallClockHandle);
  wallClockHandle = null;
}

function stopWallClock() {
  wallClockActive = false;
  suspendWallClock();
  renderWakeStatus();
}

async function releaseWakeLock() {
  if (wakeLock) await wakeLock.release().catch(() => {});
  wakeLock = null;
}

async function readBattery() {
  if (!('getBattery' in navigator)) return null;
  try {
    return await navigator.getBattery();
  } catch {
    return null;
  }
}

async function checkDeviceWarnings({ battery = false } = {}) {
  const [, status] = await Promise.all([requestWakeLock(), battery ? readBattery() : null]);
  const wake = wakeStatus.failed && !wakeWarned;
  const lowBattery = Boolean(status) && isBatteryLow(status);
  if (timerView.hidden || !(wake || lowBattery)) return;
  if (wake) wakeWarned = true;
  $('#wake-warning-text').hidden = !wake;
  $('#battery-warning-text').hidden = !lowBattery;
  if (lowBattery) $('#battery-level').textContent = `${Math.round(status.level * 100)}%`;
  $('#warning-dialog-title').textContent = wake && lowBattery ? '開始前請注意' : wake ? '螢幕可能會自動關閉' : '電量偏低';
  if (!$('#warning-dialog').open) $('#warning-dialog').showModal();
}

function phaseAfter(index) {
  return currentPlan?.phases[index + 1] ?? null;
}

function renderSnapshot(snapshot) {
  currentSnapshot = snapshot;
  const phase = snapshot.phase;
  const isCountup = phase.kind === 'countup';
  const shownSeconds = isCountup ? Math.floor(snapshot.phaseElapsedMs / 1000) : displaySeconds(snapshot.phaseRemainingMs);
  const clock = formatClock(shownSeconds);
  $('#timer-clock').textContent = clock;
  $('#timer-clock').dateTime = `PT${shownSeconds}S`;
  $('#timer-phase').textContent = phase.label;
  timerStage.dataset.phase = phase.kind;
  const fraction = phase.durationMs ? Math.min(1, snapshot.phaseElapsedMs / phase.durationMs) : 0;
  $('#progress-bar').style.transform = `scaleX(${isCountup ? fraction : 1 - fraction})`;

  if (phase.kind === 'prepare') $('#round-display').textContent = '準備開始';
  else if (phase.totalRounds > 1) $('#round-display').textContent = `第 ${phase.round}／${phase.totalRounds} 輪`;
  else $('#round-display').textContent = phase.kind === 'countup' ? '完成後按「完成」' : '全力完成';

  const next = phaseAfter(phase.index);
  $('#next-display').textContent = next ? `接下來 · ${next.label}${next.totalRounds > 1 ? ` ${next.round}` : ''}` : (isCountup ? '時間上限到會自動結束' : '最後一段');
  $('#finish-button').hidden = currentMode !== 'fortime' || phase.kind === 'prepare' || !isRunning;

  if (phase.index !== previousPhaseIndex) {
    $('#timer-live').textContent = `${phase.label}${phase.totalRounds > 1 ? `，第 ${phase.round} 輪` : ''}`;
    previousPhaseIndex = phase.index;
  }
  // Paused snapshots (including a restored run) only move the cue position, so resuming never rings.
  if (isRunning) {
    const cue = cueAt(phase, snapshot.phaseRemainingMs, lastCue);
    if (!isPaused) playCue(cue);
    lastCue = { index: phase.index, remainingMs: snapshot.phaseRemainingMs };
  }
}

async function startWorkout(event) {
  event.preventDefault();
  const config = readConfig();
  const error = validateConfig(config);
  if (error) {
    $('#form-error').textContent = error;
    return;
  }
  soundEnabled = $('#sound-enabled').checked;
  updateSoundToggleLabel();
  updateSoundVolume();
  if (soundEnabled) await unlockAudio();
  currentPlan = createPlan(config);
  currentConfig = config;
  currentMode = config.mode;
  showTimerView();
  resetTimer();
  wakeWarned = false;
  await checkDeviceWarnings({ battery: true });
}

function showTimerView() {
  $('#timer-mode').textContent = MODE_META[currentMode].label;
  setupView.hidden = true;
  $('.hero').hidden = true;
  $('.site-header').hidden = true;
  $('.feature-strip').hidden = true;
  $('footer').hidden = true;
  timerView.hidden = false;
  document.body.classList.add('timer-running');
}

async function leaveTimer() {
  if (isRunning) worker.postMessage({ type: 'stop' });
  isRunning = false;
  isPaused = false;
  clearRun();
  stopWallClock();
  await releaseWakeLock();
  timerView.hidden = true;
  setupView.hidden = false;
  $('.hero').hidden = false;
  $('.site-header').hidden = false;
  $('.feature-strip').hidden = false;
  $('footer').hidden = false;
  document.body.classList.remove('timer-running');
  $('#start-button').textContent = '開始';
  $('#form-error').textContent = '';
  setupView.scrollIntoView({ block: 'start' });
}

function resetTimer() {
  if (isRunning) worker.postMessage({ type: 'stop' });
  isRunning = false;
  isPaused = false;
  isFinished = false;
  currentSummary = null;
  $('#share-button').hidden = true;
  stopWallClock();
  clearRun();
  previousPhaseIndex = -1;
  lastCue = null;
  $('#start-button').textContent = '開始';
  renderSnapshot(snapshotAt(currentPlan, 0));
}

function toggleTimer() {
  if (isFinished) resetTimer();
  if (!isRunning) {
    if (soundEnabled) unlockAudio().catch(() => {});
    isRunning = true;
    isPaused = false;
    runId += 1;
    worker.postMessage({ type: 'start', config: currentConfig, runId });
    startWallClock();
    $('#start-button').textContent = '暫停';
    $('#timer-live').textContent = '計時開始';
    return;
  }
  isPaused = !isPaused;
  if (!isPaused && soundEnabled) unlockAudio().catch(() => {});
  worker.postMessage({ type: isPaused ? 'pause' : 'resume' });
  $('#start-button').textContent = isPaused ? '繼續' : '暫停';
  $('#timer-live').textContent = isPaused ? '計時已暫停' : '計時繼續';
}

function finishWorkout() {
  playComplete();
  if (isRunning) worker.postMessage({ type: 'stop' });
  isRunning = false;
  isPaused = false;
  isFinished = true;
  clearRun();
  currentSummary = summarizeRun(currentPlan, currentSnapshot.elapsedMs);
  const [headline, ...details] = currentSummary.lines;
  $('#timer-clock').textContent = currentSummary.time;
  $('#timer-phase').textContent = '完成';
  timerStage.dataset.phase = 'done';
  $('#progress-bar').style.transform = 'scaleX(1)';
  $('#round-display').textContent = headline;
  $('#next-display').textContent = details.join(' · ') || '按「分享」留下這次成績';
  $('#finish-button').hidden = true;
  $('#share-button').hidden = false;
  $('#start-button').textContent = '重新開始';
  $('#timer-live').textContent = `訓練完成，${currentSummary.lines.join('，')}`;
}

function openShare() {
  $('#share-status').textContent = '';
  $('#share-exercise').placeholder = currentSummary.label === 'AMRAP' ? '例如：波比跳 x 3' : '例如：波比跳';
  $('#share-dialog').showModal();
}

function loadImage(src) {
  return new Promise((resolve) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => resolve(null);
    image.src = src;
  });
}

async function renderShareImage(exercise) {
  const size = 1080;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const context = canvas.getContext('2d');
  const sans = 'system-ui,-apple-system,"PingFang TC","Noto Sans TC",sans-serif';
  const mono = 'ui-monospace,SFMono-Regular,Menlo,monospace';
  const line = (text, y, fontSize, family, color = '#fff') => {
    let shown = fontSize;
    context.font = `900 ${shown}px ${family}`;
    while (context.measureText(text).width > size - 120 && shown > 20) {
      shown -= 2;
      context.font = `900 ${shown}px ${family}`;
    }
    context.lineWidth = shown * 0.16;
    context.shadowColor = 'rgba(0,0,0,.45)';
    context.shadowBlur = shown * 0.3;
    context.strokeStyle = 'rgba(23,30,52,.92)';
    context.strokeText(text, size / 2, y);
    context.shadowColor = 'transparent';
    context.fillStyle = color;
    context.fillText(text, size / 2, y);
  };
  const logo = await loadImage('./icon.svg');
  if (logo) context.drawImage(logo, (size - 180) / 2, 90, 180, 180);
  context.textAlign = 'center';
  context.lineJoin = 'round';
  line(`我剛做了『${exercise}』！`, 400, 76, sans);
  line(currentSummary.time, 640, 230, mono);
  line(currentSummary.label, 740, 58, mono, '#ed735f');
  currentSummary.lines.forEach((text, index) => line(text, 830 + index * 70, 44, sans));
  line('BOX CLOCK', 1020, 30, mono, '#e4e6ee');
  return new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
}

async function showSharePreview(event) {
  event.preventDefault();
  const exercise = $('#share-exercise').value.trim();
  if (!exercise || !currentSummary) return;
  saveSettings();
  const blob = await renderShareImage(exercise);
  if (shareContent) URL.revokeObjectURL(shareContent.url);
  shareContent = { text: shareText(currentSummary, exercise), url: URL.createObjectURL(blob), file: new File([blob], 'box-clock.png', { type: 'image/png' }) };
  $('#share-preview-image').src = shareContent.url;
  $('#share-preview-text').textContent = shareContent.text;
  $('#share-dialog').close();
  $('#share-preview-dialog').showModal();
}

async function copyResultText() {
  try {
    await navigator.clipboard.writeText(shareContent.text);
    $('#share-status').textContent = '已複製文字，可以貼到任何地方';
  } catch {
    $('#share-status').textContent = '無法複製，請長按上方文字手動複製';
  }
}

async function shareImage() {
  if (!navigator.canShare?.({ files: [shareContent.file] })) {
    $('#share-status').textContent = '此裝置不支援分享圖片，請改用「下載浮水印」';
    return;
  }
  try {
    await navigator.share({ files: [shareContent.file] });
  } catch (error) {
    if (error.name !== 'AbortError') $('#share-status').textContent = '無法開啟分享，請改用「下載浮水印」';
  }
}

async function shareResultText() {
  if (!navigator.share) {
    $('#share-status').textContent = '此裝置不支援內建分享，請改用「複製文字」';
    return;
  }
  try {
    await navigator.share({ text: shareContent.text });
  } catch (error) {
    if (error.name !== 'AbortError') $('#share-status').textContent = '無法開啟分享，請改用「複製文字」';
  }
}

function downloadImage() {
  const link = document.createElement('a');
  link.href = shareContent.url;
  link.download = 'box-clock.png';
  link.click();
  $('#share-status').textContent = '已下載透明背景浮水印';
}

function saveRun() {
  if (!currentConfig || !currentSnapshot) return;
  try {
    localStorage.setItem(RUN_STORAGE_KEY, serializeRun({ config: currentConfig, elapsedMs: currentSnapshot.elapsedMs }));
  } catch {}
}

function clearRun() {
  try {
    localStorage.removeItem(RUN_STORAGE_KEY);
  } catch {}
}

function pauseForBackground() {
  if (!isRunning) return;
  if (!isPaused) toggleTimer();
  saveRun();
}

function restoreSavedRun() {
  let saved = null;
  try {
    saved = restoreRun(localStorage.getItem(RUN_STORAGE_KEY));
  } catch {}
  if (!saved) {
    clearRun();
    return;
  }
  soundEnabled = $('#sound-enabled').checked;
  currentConfig = saved.config;
  currentPlan = createPlan(saved.config);
  currentMode = saved.config.mode;
  showTimerView();
  isRunning = true;
  isPaused = true;
  previousPhaseIndex = -1;
  lastCue = null;
  runId += 1;
  worker.postMessage({ type: 'start', config: currentConfig, runId, elapsedMs: saved.elapsedMs, paused: true });
  startWallClock();
  $('#start-button').textContent = '繼續';
  $('#timer-live').textContent = '已還原上次暫停的訓練，按「繼續」接著計時';
  checkDeviceWarnings({ battery: true });
}

worker.addEventListener('message', ({ data }) => {
  if (!isRunning || data.runId !== runId) return;
  if (data.snapshot) renderSnapshot(data.snapshot);
  if (data.type === 'paused') saveRun();
  if (data.type === 'complete' && isRunning) finishWorkout();
});

form.addEventListener('input', (event) => {
  if (event.target.name === 'mode') updateSetup();
  else updateSummary();
  saveSettings();
});
form.addEventListener('submit', startWorkout);

$('#start-button').addEventListener('click', toggleTimer);
$('#reset-button').addEventListener('click', resetTimer);
$('#finish-button').addEventListener('click', finishWorkout);
$('#cancel-button').addEventListener('click', () => leaveTimer());
$('#share-button').addEventListener('click', openShare);
$('#share-form').addEventListener('submit', showSharePreview);
$('#copy-text-button').addEventListener('click', copyResultText);
$('#share-image-button').addEventListener('click', shareImage);
$('#share-text-button').addEventListener('click', shareResultText);
$('#download-image-button').addEventListener('click', downloadImage);
$$('[data-close-dialog]').forEach((button) => button.addEventListener('click', () => button.closest('dialog').close()));
$('#sound-volume').addEventListener('input', updateSoundVolume);
$('#sound-volume').addEventListener('change', () => {
  normalizeSoundVolume();
  updateSoundVolume();
  saveSettings();
});
$$('[data-volume-step]').forEach((button) => button.addEventListener('click', () => {
  const field = $('#sound-volume');
  normalizeSoundVolume();
  if (Number(button.dataset.volumeStep) > 0) field.stepUp();
  else field.stepDown();
  updateSoundVolume();
  saveSettings();
}));
$('#sound-enabled').addEventListener('change', updateSoundToggleLabel);
$('#test-sound-button').addEventListener('click', async () => {
  try {
    if (!(await unlockAudio())) throw new Error('audio unavailable');
    updateSoundVolume();
    playSoundPreview();
    $('#sound-test-status').textContent = `已試聽 ${Math.round(soundVolume * 100)}% 音量`;
  } catch {
    $('#sound-test-status').textContent = '此瀏覽器無法試聽';
  }
});
$('#mode-help-button').addEventListener('click', openModeHelp);
$('#mode-help-dialog').addEventListener('click', (event) => {
  if (event.target === event.currentTarget) event.currentTarget.close();
});
$('.footer-logo').addEventListener('click', (event) => {
  event.preventDefault();
  $('#mode-guide-dialog').showModal();
});
$('#mode-guide-dialog').addEventListener('click', (event) => {
  if (event.target === event.currentTarget) event.currentTarget.close();
});
document.addEventListener('visibilitychange', async () => {
  if (document.visibilityState === 'visible' && !timerView.hidden) {
    if (!wakeLock) await checkDeviceWarnings();
    if (isRunning) worker.postMessage({ type: 'sync' });
    if (wallClockActive && document.visibilityState === 'visible') tickWallClock();
  }
});
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState !== 'hidden') return;
  pauseForBackground();
  suspendWallClock();
});

function installAction() {
  // iOS 從主畫面開啟時只有 navigator.standalone 為 true，其他平台看 display-mode。
  const standalone = window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
  return installButtonAction({ standalone, hasPrompt: Boolean(installPrompt) });
}
function updateInstallButton() {
  $('#install-button').hidden = installAction() === 'hidden';
}
function showInstallPanel(platform) {
  $$('[data-install-panel]').forEach((panel) => { panel.hidden = panel.dataset.installPanel !== platform; });
  $$('[data-install-tab]').forEach((tab) => tab.setAttribute('aria-pressed', String(tab.dataset.installTab === platform)));
}
window.addEventListener('beforeinstallprompt', (event) => {
  event.preventDefault();
  installPrompt = event;
  updateInstallButton();
});
window.addEventListener('appinstalled', () => {
  installPrompt = null;
  $('#install-button').hidden = true;
});
$('#install-button').addEventListener('click', async () => {
  const action = installAction();
  if (action === 'prompt') {
    const prompt = installPrompt;
    installPrompt = null;
    await prompt.prompt();
    const { outcome } = await prompt.userChoice;
    if (outcome === 'accepted') $('#install-button').hidden = true;
    return;
  }
  if (action !== 'guide') return;
  showInstallPanel(installPlatform(navigator));
  $('#install-dialog').showModal();
});
$$('[data-install-tab]').forEach((tab) => tab.addEventListener('click', () => showInstallPanel(tab.dataset.installTab)));
$('#install-dialog').addEventListener('click', (event) => {
  if (event.target === event.currentTarget) event.currentTarget.close();
});
updateInstallButton();

if ('serviceWorker' in navigator) {
  let serviceWorkerRefreshPending = false;
  const hadServiceWorkerController = Boolean(navigator.serviceWorker.controller);
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    if (hadServiceWorkerController && !serviceWorkerRefreshPending) {
      serviceWorkerRefreshPending = true;
      window.location.reload();
    }
  });
  window.addEventListener('load', () => navigator.serviceWorker.register('./sw.js').then((registration) => registration.update()));
}
loadSettings();
updateSoundToggleLabel();
updateSoundVolume();
updateSetup();
restoreSavedRun();
EOF

cat > "$project_dir/public/manifest.webmanifest" <<'EOF'
{
  "name": "BOX CLOCK｜CrossFit 間歇計時器",
  "short_name": "BOX CLOCK",
  "description": "AMRAP、EMOM、Tabata 與 For Time 離線間歇計時器",
  "lang": "zh-Hant-TW",
  "start_url": "./",
  "scope": "./",
  "display": "standalone",
  "orientation": "any",
  "background_color": "#f5f3ed",
  "theme_color": "#171e34",
  "icons": [
    { "src": "./icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any" },
    { "src": "./icon-maskable.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "maskable" }
  ]
}
EOF

cat > "$project_dir/public/icon.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect width="512" height="512" rx="92" fill="#171e34"/>
  <rect x="222" y="84" width="68" height="32" rx="10" fill="#f5f3ed"/>
  <rect x="240" y="108" width="32" height="34" fill="#f5f3ed"/>
  <rect x="240" y="104" width="32" height="38" rx="8" fill="#ed735f" transform="rotate(45 256 284)"/>
  <circle cx="256" cy="284" r="150" fill="#f5f3ed"/>
  <circle cx="256" cy="284" r="126" fill="#171e34"/>
  <path d="M256 284V184A100 100 0 0 1 342.6 334Z" fill="#ed735f"/>
  <path d="M251 162h10v14h-10zM364 279h14v10h-14zM251 392h10v14h-10zM134 279h14v10h-14z" fill="#f5f3ed"/>
  <path d="M256 284L332.2 328" stroke="#f5f3ed" stroke-width="14" stroke-linecap="round"/>
  <circle cx="256" cy="284" r="20" fill="#f5f3ed"/>
  <circle cx="256" cy="284" r="9" fill="#7652ca"/>
</svg>
EOF

cat > "$project_dir/public/icon-maskable.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect width="512" height="512" fill="#171e34"/>
  <rect x="222" y="84" width="68" height="32" rx="10" fill="#f5f3ed"/>
  <rect x="240" y="108" width="32" height="34" fill="#f5f3ed"/>
  <rect x="240" y="104" width="32" height="38" rx="8" fill="#ed735f" transform="rotate(45 256 284)"/>
  <circle cx="256" cy="284" r="150" fill="#f5f3ed"/>
  <circle cx="256" cy="284" r="126" fill="#171e34"/>
  <path d="M256 284V184A100 100 0 0 1 342.6 334Z" fill="#ed735f"/>
  <path d="M251 162h10v14h-10zM364 279h14v10h-14zM251 392h10v14h-10zM134 279h14v10h-14z" fill="#f5f3ed"/>
  <path d="M256 284L332.2 328" stroke="#f5f3ed" stroke-width="14" stroke-linecap="round"/>
  <circle cx="256" cy="284" r="20" fill="#f5f3ed"/>
  <circle cx="256" cy="284" r="9" fill="#7652ca"/>
</svg>
EOF

base64 --decode > "$project_dir/public/apple-touch-icon.png" <<'EOF'
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
AAAGSURBVAMAZzVLd+/f8f4AAAAASUVORK5CYII=
EOF

base64 --decode > "$project_dir/public/jerry.png" <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAAABGdBTUEAALGPC/xhBQAAACBjSFJN
AAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAAhGVYSWZNTQAqAAAACAAFARIA
AwAAAAEAAQAAARoABQAAAAEAAABKARsABQAAAAEAAABSASgAAwAAAAEAAgAAh2kABAAAAAEAAABa
AAAAAAAAAEgAAAABAAAASAAAAAEAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAgKADAAQAAAABAAAA
gAAAAAC7tGl0AAAACXBIWXMAAAsTAAALEwEAmpwYAAACymlUWHRYTUw6Y29tLmFkb2JlLnhtcAAA
AAAAPHg6eG1wbWV0YSB4bWxuczp4PSJhZG9iZTpuczptZXRhLyIgeDp4bXB0az0iWE1QIENvcmUg
Ni4wLjAiPgogICA8cmRmOlJERiB4bWxuczpyZGY9Imh0dHA6Ly93d3cudzMub3JnLzE5OTkvMDIv
MjItcmRmLXN5bnRheC1ucyMiPgogICAgICA8cmRmOkRlc2NyaXB0aW9uIHJkZjphYm91dD0iIgog
ICAgICAgICAgICB4bWxuczp0aWZmPSJodHRwOi8vbnMuYWRvYmUuY29tL3RpZmYvMS4wLyIKICAg
ICAgICAgICAgeG1sbnM6ZXhpZj0iaHR0cDovL25zLmFkb2JlLmNvbS9leGlmLzEuMC8iPgogICAg
ICAgICA8dGlmZjpZUmVzb2x1dGlvbj43MjwvdGlmZjpZUmVzb2x1dGlvbj4KICAgICAgICAgPHRp
ZmY6UmVzb2x1dGlvblVuaXQ+MjwvdGlmZjpSZXNvbHV0aW9uVW5pdD4KICAgICAgICAgPHRpZmY6
WFJlc29sdXRpb24+NzI8L3RpZmY6WFJlc29sdXRpb24+CiAgICAgICAgIDx0aWZmOk9yaWVudGF0
aW9uPjE8L3RpZmY6T3JpZW50YXRpb24+CiAgICAgICAgIDxleGlmOlBpeGVsWERpbWVuc2lvbj41
MTI8L2V4aWY6UGl4ZWxYRGltZW5zaW9uPgogICAgICAgICA8ZXhpZjpDb2xvclNwYWNlPjE8L2V4
aWY6Q29sb3JTcGFjZT4KICAgICAgICAgPGV4aWY6UGl4ZWxZRGltZW5zaW9uPjUxMjwvZXhpZjpQ
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
AAAAAElFTkSuQmCC
EOF

cat > "$project_dir/public/sw.js" <<'EOF'
const CACHE_NAME = 'box-clock-v30';
const APP_SHELL = ['./', './index.html', './styles.css', './app.js', './timer-core.mjs', './run-state.mjs', './device.mjs', './timer-worker.js', './manifest.webmanifest', './icon.svg', './icon-maskable.svg', './apple-touch-icon.png', './jerry.png'];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key)))).then(() => self.clients.claim()));
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET' || new URL(event.request.url).origin !== self.location.origin) return;
  const networkFirst = event.request.mode === 'navigate' || ['script', 'style', 'worker', 'manifest'].includes(event.request.destination);
  const updateCache = (response) => {
    if (response.ok) caches.open(CACHE_NAME).then((cache) => cache.put(event.request, response.clone()));
    return response;
  };
  if (networkFirst) {
    event.respondWith(fetch(event.request).then(updateCache).catch(() => caches.match(event.request).then((cached) => cached || caches.match('./index.html'))));
    return;
  }
  event.respondWith(caches.match(event.request).then((cached) => cached || fetch(event.request).then(updateCache).catch(() => caches.match('./index.html'))));
});
EOF

cat > "$project_dir/tests/timer-core.test.mjs" <<'EOF'
import test from 'node:test';
import assert from 'node:assert/strict';
import { createPlan, cueAt, displaySeconds, formatClock, normalizeConfig, shareText, snapshotAt, summarizeRun } from '../src/timer-core.mjs';

test('AMRAP includes preparation and countdown work phase', () => {
  const plan = createPlan({ mode: 'amrap', prep: 10, duration: 720 });
  assert.equal(plan.phases.length, 2);
  assert.equal(plan.totalMs, 730000);
  assert.equal(snapshotAt(plan, 9999).phase.kind, 'prepare');
  assert.equal(snapshotAt(plan, 10000).phase.kind, 'work');
});

test('EMOM creates one interval per round', () => {
  const plan = createPlan({ mode: 'emom', prep: 0, rounds: 10, interval: 60 });
  assert.equal(plan.phases.length, 10);
  assert.equal(plan.totalMs, 600000);
  assert.equal(snapshotAt(plan, 60000).phase.round, 2);
});

test('Tabata omits rest after the final round', () => {
  const plan = createPlan({ mode: 'tabata', prep: 0, rounds: 8, work: 20, rest: 10 });
  assert.equal(plan.phases.length, 15);
  assert.equal(plan.totalMs, 230000);
  assert.equal(plan.phases.at(-1).kind, 'work');
});

test('For Time counts upward against a cap', () => {
  const plan = createPlan({ mode: 'fortime', prep: 5, cap: 1200 });
  const snapshot = snapshotAt(plan, 65000);
  assert.equal(snapshot.phase.kind, 'countup');
  assert.equal(snapshot.phaseElapsedMs, 60000);
});

test('snapshot completes exactly at total duration', () => {
  const plan = createPlan({ mode: 'amrap', prep: 0, duration: 60 });
  assert.equal(snapshotAt(plan, 59999).complete, false);
  assert.equal(snapshotAt(plan, 60000).complete, true);
});

test('normalization rejects out-of-range values', () => {
  assert.deepEqual(normalizeConfig({ mode: 'emom', prep: 99, rounds: 0, interval: 0 }), { mode: 'emom', prep: 10, rounds: 10, interval: 60 });
});

test('display formatting uses ceil for countdown and floor-ready clock text', () => {
  assert.equal(displaySeconds(3001), 4);
  assert.equal(displaySeconds(3000), 3);
  assert.equal(formatClock(125), '02:05');
});

test('a finished Tabata summarizes every round and the time without preparation', () => {
  const plan = createPlan({ mode: 'tabata', prep: 10, rounds: 8, work: 20, rest: 10 });
  assert.deepEqual(summarizeRun(plan, plan.totalMs), {
    label: 'TABATA',
    time: '03:50',
    lines: ['完成 8／8 輪', '動作 20 秒／休息 10 秒 · 總時長 03:50']
  });
});

test('a Tabata ended early counts only fully finished work rounds', () => {
  const plan = createPlan({ mode: 'tabata', prep: 0, rounds: 8, work: 20, rest: 10 });
  assert.deepEqual(summarizeRun(plan, 75000).lines, ['完成 2／8 輪', '動作 20 秒／休息 10 秒 · 總時長 01:15']);
});

test('a finished EMOM summarizes rounds and interval', () => {
  const plan = createPlan({ mode: 'emom', prep: 0, rounds: 10, interval: 60 });
  assert.deepEqual(summarizeRun(plan, plan.totalMs), {
    label: 'EMOM',
    time: '10:00',
    lines: ['完成 10／10 輪', '每輪 01:00 · 總時長 10:00']
  });
});

test('a finished AMRAP reports the full duration', () => {
  const plan = createPlan({ mode: 'amrap', prep: 5, duration: 1200 });
  assert.deepEqual(summarizeRun(plan, plan.totalMs), { label: 'AMRAP', time: '20:00', lines: ['固定時間 20:00 完成'] });
});

test('For Time finished by hand reports the score against the cap', () => {
  const plan = createPlan({ mode: 'fortime', prep: 10, cap: 600 });
  assert.deepEqual(summarizeRun(plan, 165400), { label: 'FOR TIME', time: '02:35', lines: ['成績 02:35', '時間上限 10:00'] });
});

test('For Time that reaches the cap says so', () => {
  const plan = createPlan({ mode: 'fortime', prep: 10, cap: 600 });
  assert.deepEqual(summarizeRun(plan, plan.totalMs), { label: 'FOR TIME', time: '10:00', lines: ['達到時間上限 10:00'] });
});

test('share text names the exercise and carries the result', () => {
  const summary = { label: 'TABATA', time: '03:50', lines: ['完成 8／8 輪', '動作 20 秒／休息 10 秒 · 總時長 03:50'] };
  assert.equal(shareText(summary, '  波比跳 '), '我剛做了『波比跳』！\nTABATA · 完成 8／8 輪 · 動作 20 秒／休息 10 秒 · 總時長 03:50');
});

test('a fresh start rings the bell when the first phase is work', () => {
  const plan = createPlan({ mode: 'amrap', prep: 0, duration: 720 });
  const { phase, phaseRemainingMs } = snapshotAt(plan, 0);
  assert.equal(cueAt(phase, phaseRemainingMs, null), 'round-start');
});

test('preparation starts silently and the work after it rings the bell', () => {
  const plan = createPlan({ mode: 'amrap', prep: 10, duration: 720 });
  const prepare = snapshotAt(plan, 0);
  assert.equal(cueAt(prepare.phase, prepare.phaseRemainingMs, null), null);
  const work = snapshotAt(plan, 10000);
  assert.equal(cueAt(work.phase, work.phaseRemainingMs, { index: 0, remainingMs: 16 }), 'round-start');
});

test('entering rest ends the round with the bell', () => {
  const plan = createPlan({ mode: 'tabata', prep: 0, rounds: 8, work: 20, rest: 10 });
  const rest = snapshotAt(plan, 20000);
  assert.equal(cueAt(rest.phase, rest.phaseRemainingMs, { index: 0, remainingMs: 16 }), 'round-end');
});

test('ticks inside the same phase stay silent', () => {
  const plan = createPlan({ mode: 'amrap', prep: 0, duration: 720 });
  const tick = snapshotAt(plan, 5000);
  assert.equal(cueAt(tick.phase, tick.phaseRemainingMs, { index: 0, remainingMs: 715016 }), null);
});

test('the last ten seconds of work knock the clapper once', () => {
  const plan = createPlan({ mode: 'amrap', prep: 0, duration: 720 });
  const crossing = snapshotAt(plan, 710000);
  assert.equal(cueAt(crossing.phase, crossing.phaseRemainingMs, { index: 0, remainingMs: 10016 }), 'warning');
  const after = snapshotAt(plan, 710016);
  assert.equal(cueAt(after.phase, after.phaseRemainingMs, { index: 0, remainingMs: 10000 }), null);
});

test('For Time knocks the clapper ten seconds before the cap', () => {
  const plan = createPlan({ mode: 'fortime', prep: 0, cap: 600 });
  const crossing = snapshotAt(plan, 590000);
  assert.equal(cueAt(crossing.phase, crossing.phaseRemainingMs, { index: 0, remainingMs: 10016 }), 'warning');
});

test('rest and work of ten seconds or less never knock the clapper', () => {
  const tabata = createPlan({ mode: 'tabata', prep: 0, rounds: 8, work: 20, rest: 30 });
  const rest = snapshotAt(tabata, 40000);
  assert.equal(cueAt(rest.phase, rest.phaseRemainingMs, { index: 1, remainingMs: 10016 }), null);
  const emom = createPlan({ mode: 'emom', prep: 0, rounds: 10, interval: 10 });
  const tick = snapshotAt(emom, 16);
  assert.equal(cueAt(tick.phase, tick.phaseRemainingMs, { index: 0, remainingMs: 10000 }), null);
});

test('preparation ticks once per second over its last five seconds', () => {
  const plan = createPlan({ mode: 'amrap', prep: 10, duration: 720 });
  const six = snapshotAt(plan, 4000);
  assert.equal(cueAt(six.phase, six.phaseRemainingMs, { index: 0, remainingMs: 6016 }), null);
  const five = snapshotAt(plan, 5000);
  assert.equal(cueAt(five.phase, five.phaseRemainingMs, { index: 0, remainingMs: 5016 }), 'tick');
  const between = snapshotAt(plan, 5016);
  assert.equal(cueAt(between.phase, between.phaseRemainingMs, { index: 0, remainingMs: 5000 }), null);
  const one = snapshotAt(plan, 9000);
  assert.equal(cueAt(one.phase, one.phaseRemainingMs, { index: 0, remainingMs: 1016 }), 'tick');
});

test('a five second preparation ticks as soon as it starts', () => {
  const plan = createPlan({ mode: 'amrap', prep: 5, duration: 720 });
  const start = snapshotAt(plan, 0);
  assert.equal(cueAt(start.phase, start.phaseRemainingMs, null), 'tick');
});

test('rest ticks over its last five seconds before the next round', () => {
  const tabata = createPlan({ mode: 'tabata', prep: 0, rounds: 8, work: 20, rest: 10 });
  const five = snapshotAt(tabata, 25000);
  assert.equal(cueAt(five.phase, five.phaseRemainingMs, { index: 1, remainingMs: 5016 }), 'tick');
  const short = createPlan({ mode: 'tabata', prep: 0, rounds: 8, work: 20, rest: 5 });
  const entry = snapshotAt(short, 20000);
  assert.equal(cueAt(entry.phase, entry.phaseRemainingMs, { index: 0, remainingMs: 16 }), 'round-end');
  const four = snapshotAt(short, 21000);
  assert.equal(cueAt(four.phase, four.phaseRemainingMs, { index: 1, remainingMs: 4016 }), 'tick');
});

test('work ticks once per second over its last three seconds', () => {
  const plan = createPlan({ mode: 'amrap', prep: 0, duration: 720 });
  const four = snapshotAt(plan, 716000);
  assert.equal(cueAt(four.phase, four.phaseRemainingMs, { index: 0, remainingMs: 4016 }), null);
  const three = snapshotAt(plan, 717000);
  assert.equal(cueAt(three.phase, three.phaseRemainingMs, { index: 0, remainingMs: 3016 }), 'tick');
  const one = snapshotAt(plan, 719000);
  assert.equal(cueAt(one.phase, one.phaseRemainingMs, { index: 0, remainingMs: 1016 }), 'tick');
});

test('For Time ticks over the last three seconds before the cap', () => {
  const plan = createPlan({ mode: 'fortime', prep: 0, cap: 600 });
  const three = snapshotAt(plan, 597000);
  assert.equal(cueAt(three.phase, three.phaseRemainingMs, { index: 0, remainingMs: 3016 }), 'tick');
});

test('For Time accepts a cap as short as 1 second', () => {
  assert.equal(normalizeConfig({ mode: 'fortime', prep: 0, cap: 1 }).cap, 1);
  assert.equal(normalizeConfig({ mode: 'fortime', prep: 0, cap: 0 }).cap, 1200);
});

test('AMRAP accepts a duration as short as 1 second', () => {
  assert.equal(normalizeConfig({ mode: 'amrap', prep: 0, duration: 1 }).duration, 1);
  assert.equal(normalizeConfig({ mode: 'amrap', prep: 0, duration: 0 }).duration, 720);
});

test('EMOM accepts one round of one second', () => {
  assert.deepEqual(normalizeConfig({ mode: 'emom', prep: 0, rounds: 1, interval: 1 }), { mode: 'emom', prep: 0, rounds: 1, interval: 1 });
  assert.equal(normalizeConfig({ mode: 'emom', prep: 0, rounds: 1, interval: 0 }).interval, 60);
});

test('Tabata accepts one round of one second with no rest', () => {
  assert.deepEqual(normalizeConfig({ mode: 'tabata', prep: 0, rounds: 1, work: 1, rest: 0 }), { mode: 'tabata', prep: 0, rounds: 1, work: 1, rest: 0 });
  assert.equal(normalizeConfig({ mode: 'tabata', prep: 0, rounds: 1, work: 0, rest: 0 }).work, 20);
});
EOF

cat > "$project_dir/tests/run-state.test.mjs" <<'EOF'
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRunClock, formatTimeOfDay, msUntilNextSecond, restoreRun, resumeAudio, serializeRun } from '../src/run-state.mjs';

function fakeNow(start = 1000) {
  let value = start;
  const now = () => value;
  now.advance = (ms) => { value += ms; };
  return now;
}

test('run clock excludes paused time from elapsed', () => {
  const now = fakeNow();
  const clock = createRunClock(now);
  clock.start();
  now.advance(5000);
  clock.pause();
  now.advance(60000);
  assert.equal(clock.elapsed(), 5000);
  clock.resume();
  now.advance(2000);
  assert.equal(clock.elapsed(), 7000);
});

test('run clock restarts paused at a saved elapsed time', () => {
  const now = fakeNow();
  const clock = createRunClock(now);
  clock.start({ elapsedMs: 42000, paused: true });
  now.advance(3600000);
  assert.equal(clock.elapsed(), 42000);
  clock.resume();
  now.advance(1000);
  assert.equal(clock.elapsed(), 43000);
});

test('a saved run restores its config and paused elapsed time', () => {
  const config = { mode: 'tabata', prep: 10, rounds: 8, work: 20, rest: 10 };
  const text = serializeRun({ config, elapsedMs: 95000 });
  assert.deepEqual(restoreRun(text), { config: { mode: 'tabata', prep: 10, rounds: 8, work: 20, rest: 10 }, elapsedMs: 95000 });
});

test('unusable saved runs restore as nothing', () => {
  assert.equal(restoreRun(null), null);
  assert.equal(restoreRun('{broken'), null);
  assert.equal(restoreRun('42'), null);
  assert.equal(restoreRun('{"config":{"mode":"amrap","prep":0,"duration":600},"elapsedMs":-1}'), null);
  assert.equal(restoreRun('{"config":{"mode":"amrap","prep":0,"duration":600},"elapsedMs":"abc"}'), null);
  assert.equal(restoreRun('{"config":{"mode":"yoga","prep":0},"elapsedMs":1000}'), null);
  assert.equal(restoreRun('{"elapsedMs":1000}'), null);
});

test('a saved run that already reached its total duration restores as nothing', () => {
  const config = { mode: 'amrap', prep: 0, duration: 600 };
  assert.equal(restoreRun(serializeRun({ config, elapsedMs: 600000 })), null);
  assert.equal(restoreRun(serializeRun({ config, elapsedMs: 599999 })).elapsedMs, 599999);
});

function fakeAudioContext(state, { rejects = false } = {}) {
  const context = {
    state,
    resumeCalls: 0,
    async resume() {
      context.resumeCalls += 1;
      if (rejects) throw new Error('blocked');
      context.state = 'running';
    }
  };
  return context;
}

test('audio interrupted while away is resumed', async () => {
  const context = fakeAudioContext('interrupted');
  assert.equal(await resumeAudio(context), true);
  assert.equal(context.state, 'running');
});

test('audio that cannot resume reports false instead of throwing', async () => {
  assert.equal(await resumeAudio(fakeAudioContext('suspended', { rejects: true })), false);
  assert.equal(await resumeAudio(null), false);
});

test('time of day shows hours, minutes and seconds', () => {
  assert.equal(formatTimeOfDay(new Date(2026, 9, 25, 14, 20, 5)), '14:20:05');
  assert.equal(formatTimeOfDay(new Date(2026, 9, 25, 9, 3, 59)), '09:03:59');
});

test('wall clock waits until the next whole second', () => {
  assert.equal(msUntilNextSecond(1761373205250), 750);
  assert.equal(msUntilNextSecond(1761373205999), 1);
  assert.equal(msUntilNextSecond(1761373206000), 1000);
});
EOF

cat > "$project_dir/tests/device.test.mjs" <<'EOF'
import test from 'node:test';
import assert from 'node:assert/strict';
import { installButtonAction, installPlatform, isBatteryLow } from '../src/device.mjs';

test('battery below 30 percent and not charging is low', () => {
  assert.equal(isBatteryLow({ level: 0.29, charging: false }), true);
  assert.equal(isBatteryLow({ level: 0.05, charging: false }), true);
});

test('battery at or above 30 percent is not low', () => {
  assert.equal(isBatteryLow({ level: 0.3, charging: false }), false);
  assert.equal(isBatteryLow({ level: 0.8, charging: false }), false);
});

test('charging battery is not low', () => {
  assert.equal(isBatteryLow({ level: 0.1, charging: true }), false);
});

test('install button is hidden when already running as an installed app', () => {
  assert.equal(installButtonAction({ standalone: true, hasPrompt: false }), 'hidden');
  assert.equal(installButtonAction({ standalone: true, hasPrompt: true }), 'hidden');
});

test('install button prompts when the browser offers one-tap install', () => {
  assert.equal(installButtonAction({ standalone: false, hasPrompt: true }), 'prompt');
});

test('install button opens the guide when the browser has no install prompt', () => {
  assert.equal(installButtonAction({ standalone: false, hasPrompt: false }), 'guide');
});

test('iPhone and iPad user agents use the iOS install guide', () => {
  assert.equal(installPlatform({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1', maxTouchPoints: 5 }), 'ios');
  assert.equal(installPlatform({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0.7390.41 Mobile/15E148 Safari/604.1', maxTouchPoints: 5 }), 'ios');
  assert.equal(installPlatform({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15', maxTouchPoints: 5 }), 'ios');
});

test('Android user agents use the Android install guide', () => {
  assert.equal(installPlatform({ userAgent: 'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36', maxTouchPoints: 5 }), 'android');
});

test('desktop user agents use the desktop install guide', () => {
  assert.equal(installPlatform({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15', maxTouchPoints: 0 }), 'desktop');
  assert.equal(installPlatform({ userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36', maxTouchPoints: 0 }), 'desktop');
});
EOF

cat > "$project_dir/README.md" <<'EOF'
# BOX CLOCK

為 CrossFit 與功能性體能訓練設計的單頁間歇計時器。支援 AMRAP、EMOM、Tabata、For Time，沒有帳號、廣告、追蹤或訓練紀錄。

線上版：<https://box-clock.jlab-app.cloud>

使用說明：[手機操作步驟與示範動畫](docs/usage.md)

## 功能

- Web Worker 以單調時鐘校正經過時間，避免每秒遞減造成累積誤差。
- AMRAP、EMOM、Tabata、For Time 四種原生流程。
- 拳擊比賽鐘聲提示：動作開始敲一下、進入休息與完訓連敲三下、動作剩 10 秒敲木板，動作最後 3 秒與準備、休息的最後 5 秒每秒敲一聲，可調整音量並試聽。
- Screen Wake Lock API 讓支援的瀏覽器在計時中保持螢幕常亮。
- PWA 應用程式殼層離線快取，可安裝至主畫面。
- 行動裝置、橫向顯示、鍵盤操作與螢幕閱讀器狀態提示。
- 離開畫面（切換 App、鎖定螢幕）時自動暫停並保存進度；回到畫面或 App 被系統關閉後重開，都停在暫停點，按「繼續」接著計時。
- 訓練結束停在結果畫面（FOR TIME 成績、TABATA／EMOM 完成輪數與總時長），可複製或分享成績文字，並下載在本機產生的透明背景浮水印圖片。
- 螢幕常亮無法啟用時以紅色標示並跳出提醒；按開始後頂列改顯示現在時間（時:分:秒）。

## 隱私

所有設定與計時都在瀏覽器中執行，不送出，也沒有第三方分析程式。訓練模式、準備倒數、聲音與各模式的時間設定只記在本機瀏覽器的 `localStorage`，下次開啟時沿用。暫停中的訓練進度也只存在 `localStorage`，結束、重設或返回設定時清除。

## 本機開發

```sh
python3 -m http.server 4173 --directory dist
```

瀏覽 `http://localhost:4173`。Service Worker、Wake Lock 與安裝提示需要 `localhost` 或 HTTPS。

## 建置與驗證

```sh
npm run build
npm run verify
```

建置輸出位於 `dist/`。建置只產生本機檔案；發布需另執行 `npm run deploy -- <Cloudflare Pages 專案名稱>`。

## 專案結構

- `src/`：頁面、樣式、互動、Web Worker、計時核心，以及計時時鐘、進度保存與音訊恢復（`run-state.mjs`）、電量判斷（`device.mjs`）。
- `public/`：PWA manifest、Service Worker 與圖示。
- `tests/`：計時狀態、時鐘、進度保存與音訊恢復的邊界測試。
- `scripts/`：專案產生、建置、驗證與發布流程。
- `docs/`：使用說明與操作示範 GIF；介面改版後以 `sh scripts/record-usage-gifs.sh` 重新錄製（需要 ffmpeg）。
EOF

cat > "$project_dir/.gitignore" <<'EOF'
dist/
.wrangler/
.DS_Store

# AI agent 指引（僅本機）
AGENTS.md
CLAUDE.md
.claude/

# 相依套件與紀錄
node_modules/
*.log

# 環境變數與機密
.env
.env.*

# 編輯器與系統檔
.vscode/
.idea/
Thumbs.db
EOF

printf 'Project files generated in %s\n' "$project_dir"
