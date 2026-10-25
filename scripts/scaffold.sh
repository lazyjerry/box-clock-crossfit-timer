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
  if (mode === 'amrap') return { mode, prep, duration: clampInteger(raw.duration, 60, 99 * 60 + 59, MODE_DEFAULTS.amrap.duration) };
  if (mode === 'emom') return {
    mode,
    prep,
    rounds: clampInteger(raw.rounds, 1, 99, MODE_DEFAULTS.emom.rounds),
    interval: clampInteger(raw.interval, 10, 15 * 60, MODE_DEFAULTS.emom.interval)
  };
  if (mode === 'tabata') return {
    mode,
    prep,
    rounds: clampInteger(raw.rounds, 1, 99, MODE_DEFAULTS.tabata.rounds),
    work: clampInteger(raw.work, 5, 15 * 60, MODE_DEFAULTS.tabata.work),
    rest: clampInteger(raw.rest, 0, 15 * 60, MODE_DEFAULTS.tabata.rest)
  };
  return { mode, prep, cap: clampInteger(raw.cap, 30, 99 * 60 + 59, MODE_DEFAULTS.fortime.cap) };
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
      <p class="eyebrow">CROSSFIT INTERVAL TIMER</p>
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
              <div class="time-field"><label for="amrap-minutes">訓練時間</label><div><input id="amrap-minutes" name="amrapMinutes" type="number" min="1" max="99" value="12" inputmode="numeric" required><span>分</span><input id="amrap-seconds" name="amrapSeconds" type="number" min="0" max="59" value="0" inputmode="numeric" aria-label="AMRAP 秒數" required><span>秒</span></div></div>
            </div>

            <div class="mode-settings" data-mode="emom" hidden>
              <div class="field-pair">
                <div><label for="emom-rounds">總輪數</label><div class="unit-input"><input id="emom-rounds" name="emomRounds" type="number" min="1" max="99" value="10" inputmode="numeric" required><span>輪</span></div></div>
                <div><label for="emom-interval">每輪間隔</label><div class="unit-input"><input id="emom-interval" name="emomInterval" type="number" min="10" max="900" value="60" inputmode="numeric" required><span>秒</span></div></div>
              </div>
            </div>

            <div class="mode-settings" data-mode="tabata" hidden>
              <div class="field-trio">
                <div><label for="tabata-rounds">總輪數</label><div class="unit-input"><input id="tabata-rounds" name="tabataRounds" type="number" min="1" max="99" value="8" inputmode="numeric" required><span>輪</span></div></div>
                <div><label for="tabata-work">動作</label><div class="unit-input"><input id="tabata-work" name="tabataWork" type="number" min="5" max="900" value="20" inputmode="numeric" required><span>秒</span></div></div>
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

    <footer>BOX CLOCK <span>·</span> LOCAL ONLY <span>·</span> NO ACCOUNT <span>·</span> NO WORKOUT HISTORY</footer>
  </main>
  <script type="module" src="./app.js"></script>
</body>
</html>
EOF

cat > "$project_dir/src/styles.css" <<'EOF'
[hidden]{display:none!important}
.sound-settings{margin-bottom:22px}.sound-copy strong,.sound-copy small{display:block}.sound-copy strong{color:var(--ink);font-size:13px}.sound-copy small{margin-top:4px;color:var(--muted);font-size:11px}.sound-switch{display:flex;align-items:center;gap:9px;min-height:32px;color:var(--ink);font-size:12px;font-weight:850;cursor:pointer}.sound-switch input{position:absolute;opacity:0;pointer-events:none}.sound-switch-track{width:46px;height:26px;display:block;position:relative;flex:0 0 auto;background:#d4d2cc;border:1px solid #aaa8a1;border-radius:13px;transition:.15s}.sound-switch-track>span{width:20px;height:20px;position:absolute;top:2px;left:2px;background:#fff;border:1px solid #aaa8a1;border-radius:50%;box-shadow:1px 1px 0 rgba(23,30,52,.12);transition:.15s}.sound-switch input:checked+.sound-switch-track{background:var(--purple);border-color:var(--purple)}.sound-switch input:checked+.sound-switch-track>span{transform:translateX(20px);border-color:#fff}.sound-switch input:focus-visible+.sound-switch-track{outline:3px solid rgba(118,82,202,.25);outline-offset:3px}.sound-switch-label{min-width:25px}.sound-controls{display:flex;flex-wrap:wrap;align-items:center;gap:10px;padding-top:12px}.volume-label{margin:0 0 0 auto;color:var(--ink)}.volume-stepper{display:flex;align-items:center;height:40px;background:#fff;border:1px solid #bfc0c4}.volume-stepper button{width:38px;height:100%;padding:0;color:var(--purple);background:transparent;border:0;font-size:18px;font-weight:850;line-height:1}.volume-stepper button:hover:not(:disabled){color:#fff;background:var(--purple)}.volume-stepper button:disabled{opacity:.35;cursor:default}.volume-stepper input[type=number]{width:36px;height:100%;padding:0;border:0;text-align:right;font-size:15px;appearance:textfield;-moz-appearance:textfield}.volume-stepper input::-webkit-inner-spin-button,.volume-stepper input::-webkit-outer-spin-button{margin:0;-webkit-appearance:none}.volume-stepper span{padding:0 4px 0 1px;color:var(--muted);font-size:12px;font-weight:800}.volume-notes{padding:8px 0 16px;border-bottom:1px solid var(--line)}.volume-note{margin:0;color:var(--muted);font-size:11px;line-height:1.45}.test-sound-button{min-height:40px;padding:0 14px;color:var(--purple);background:#fff;border:1px solid color-mix(in srgb,var(--purple) 48%,var(--line));font-size:12px;font-weight:850}.test-sound-button:hover{color:#fff;background:var(--purple)}
:root{color-scheme:light;--paper:#f5f3ed;--card:#fffef9;--ink:#171e34;--muted:#707486;--line:#d4d2cc;--coral:#ed735f;--purple:#7652ca;--green:#398a70;--yellow:#e2a62d;--danger:#c6473a;font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans TC",sans-serif}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;color:var(--ink);background:linear-gradient(rgba(23,30,52,.05) 1px,transparent 1px),linear-gradient(90deg,rgba(23,30,52,.05) 1px,transparent 1px),var(--paper);background-size:24px 24px}button,input,select{font:inherit}button{cursor:pointer}button:focus-visible,input:focus-visible,select:focus-visible{outline:3px solid color-mix(in srgb,var(--coral) 35%,transparent);outline-offset:2px}main{min-height:100vh;padding-bottom:34px}.site-header,.hero,.tool-card,.feature-strip,footer{width:min(1180px,calc(100% - 48px));margin-inline:auto}.site-header{padding:28px 0 8px;display:flex;justify-content:space-between;align-items:center;gap:16px}.brand{display:flex;align-items:center;gap:11px;color:var(--ink);text-decoration:none;font:800 11px/1 ui-monospace,monospace;letter-spacing:.18em}.brand-mark{width:34px;height:34px;display:block}.status-pills{display:flex;align-items:center;gap:10px}.status-pill{display:flex;align-items:center;gap:8px;color:var(--muted);font:800 10px/1 ui-monospace,monospace;letter-spacing:.12em}.status-pill i{width:8px;height:8px;background:var(--green);border-radius:50%}.install-button{padding:8px 10px;color:var(--ink);background:transparent;border:1px solid var(--ink);font:800 10px/1 ui-monospace,monospace;letter-spacing:.08em}.hero{padding:58px 0 44px;border-bottom:3px solid var(--ink)}.eyebrow{margin:0 0 18px;color:var(--coral);font:800 12px/1 ui-monospace,monospace;letter-spacing:.22em}.hero-grid{display:grid;grid-template-columns:1.2fr .8fr;align-items:end;gap:56px}h1{margin:0;font-size:clamp(54px,8vw,102px);line-height:1;letter-spacing:-.065em;font-weight:950}h1 span,h1 em{display:block;font-style:normal}h1 em{color:transparent;-webkit-text-stroke:2px var(--ink);text-shadow:4px 4px 0 rgba(23,30,52,.1)}.lede{margin:0 0 7px;padding:6px 0 6px 22px;border-left:5px solid var(--coral);font-size:16px;font-weight:650;line-height:1.8}.tool-card{margin-top:38px;background:var(--card);border:1px solid var(--line);border-top:7px solid var(--coral);box-shadow:7px 7px 0 rgba(23,30,52,.11)}.section-heading{display:flex;align-items:center;gap:18px;padding:32px}.section-number{width:56px;height:56px;display:grid;place-items:center;flex:0 0 auto;color:#fff;background:var(--coral);border-radius:50%;font:800 14px/1 ui-monospace,monospace}.section-heading h2{margin:0;font-size:clamp(26px,4vw,34px);letter-spacing:-.035em}.section-heading p{margin:6px 0 0;color:var(--muted);font-size:14px}.mode-picker{margin:0;padding:0 32px 32px;border:0}.mode-picker legend{margin-bottom:12px;color:#555a6d;font-size:12px;font-weight:850;letter-spacing:.04em}.mode-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}.mode-option{position:relative;min-width:0}.mode-option input{position:absolute;opacity:0}.mode-option span{height:100%;display:block;padding:18px 16px;background:#f8f7f2;border:1px solid var(--line);transition:.15s}.mode-option strong,.mode-option small{display:block}.mode-option strong{font:900 16px/1 ui-monospace,monospace;letter-spacing:.03em}.mode-option small{margin-top:8px;color:var(--muted);font-size:11px;line-height:1.45}.mode-option input:checked+span{color:#fff;background:var(--ink);border-color:var(--ink);box-shadow:4px 4px 0 var(--coral)}.mode-option input:checked+span small{color:#e4e6ee}.mode-option input:focus-visible+span{outline:3px solid rgba(237,115,95,.3);outline-offset:2px}.settings-layout{display:grid;grid-template-columns:1.15fr .85fr;border-top:1px solid var(--line)}.settings-panel,.start-panel{padding:32px}.settings-panel{background:#faf9f5;border-right:1px solid var(--line)}.start-panel{background:#f1efe8}.panel-title{margin-bottom:26px}.panel-title span,.panel-title small{display:block}.panel-title span{font-size:18px;font-weight:900}.panel-title small{margin-top:6px;color:var(--muted);font-size:12px;line-height:1.5}label{color:#555a6d;font-size:12px;font-weight:800}.time-field>label,.field-pair label,.field-trio label,.start-panel>label{display:block;margin-bottom:9px}.time-field>div{display:grid;grid-template-columns:minmax(0,1fr) auto minmax(0,1fr) auto;align-items:center;gap:10px}.time-field span,.unit-input span{color:var(--muted);font-size:12px;font-weight:800}input[type=number],select{width:100%;height:52px;padding:0 13px;color:var(--ink);background:#fff;border:1px solid #bfc0c4;border-radius:0;font-weight:850;font-variant-numeric:tabular-nums}.field-pair,.field-trio{display:grid;gap:15px}.field-pair{grid-template-columns:1fr 1fr}.field-trio{grid-template-columns:repeat(3,1fr)}.unit-input{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:8px}.quick-presets{margin-top:25px;padding-top:22px;border-top:1px solid var(--line)}.quick-presets>span{display:block;margin-bottom:10px;color:#555a6d;font-size:11px;font-weight:850}.quick-presets>div{display:flex;flex-wrap:wrap;gap:8px}.preset-button{width:auto;min-height:36px;padding:0 13px;color:var(--purple);background:#fff;border:1px solid color-mix(in srgb,var(--purple) 45%,var(--line));font-size:11px;font-weight:850}.preset-button:hover{color:#fff;background:var(--purple)}select{margin-bottom:24px}.toggle-row{display:grid;grid-template-columns:1fr auto;align-items:center;position:relative;margin:0 0 22px;cursor:pointer}.toggle-row strong,.toggle-row small{display:block}.toggle-row strong{color:var(--ink);font-size:13px}.toggle-row small{margin-top:4px;color:var(--muted);font-size:11px}.toggle-row input{position:absolute;opacity:0}.toggle-row i{width:44px;height:24px;position:relative;background:#c9c7c1;border:1px solid #b6b4ae;transition:.15s}.toggle-row i::after{content:"";width:17px;height:17px;position:absolute;top:2px;left:2px;background:#fff;border:1px solid #aaa8a1;transition:.15s}.toggle-row input:checked+i{background:var(--purple);border-color:var(--purple)}.toggle-row input:checked+i::after{transform:translateX(20px);border-color:#fff}.toggle-row input:focus-visible+i{outline:3px solid rgba(118,82,202,.22);outline-offset:2px}.workout-summary{display:block;min-height:72px;margin-bottom:12px;padding:13px 14px;background:#fff;border-left:5px solid var(--purple);font-size:13px;font-weight:750;line-height:1.6}.workout-summary strong{display:block;font-size:17px}.form-error{min-height:19px;margin:0 0 8px;color:var(--danger);font-size:12px;font-weight:750}.primary-button{width:100%;min-height:54px;display:flex;justify-content:space-between;align-items:center;padding:0 18px;color:#fff;background:var(--ink);border:1px solid var(--ink);font-weight:900}.primary-button:hover{background:var(--coral);border-color:var(--coral)}.primary-button span{font-size:20px}.timer-view{min-height:calc(100vh - 32px);margin:16px;background:var(--ink);color:#fff;border:1px solid #3b435b;display:grid;grid-template-rows:auto 1fr auto;overflow:hidden}.timer-view[hidden]{display:none}.timer-topline{display:flex;justify-content:space-between;gap:16px;padding:19px 24px;border-bottom:1px solid #3a4258;color:#bbc1d1;font:800 11px/1 ui-monospace,monospace;letter-spacing:.12em}.timer-stage{display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:0;padding:24px;text-align:center}.timer-phase{margin:0 0 4px;color:var(--coral);font:900 clamp(24px,4vw,48px)/1 ui-monospace,monospace;letter-spacing:.1em}.timer-stage[data-phase=rest] .timer-phase{color:#8b70df}.timer-stage[data-phase=work] .timer-phase,.timer-stage[data-phase=countup] .timer-phase{color:#56b99a}.timer-clock{font:950 clamp(92px,25vw,300px)/.9 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:-.1em;font-variant-numeric:tabular-nums}.progress-track{width:min(680px,86vw);height:9px;margin:34px 0 24px;background:#353e54}.progress-track span{display:block;width:100%;height:100%;background:var(--coral);transform-origin:left center}.timer-stage[data-phase=rest] .progress-track span{background:#8b70df}.timer-stage[data-phase=work] .progress-track span,.timer-stage[data-phase=countup] .progress-track span{background:#56b99a}.round-display{margin:0;font-size:clamp(20px,3vw,36px);font-weight:900}.next-display{margin:9px 0 0;color:#9fa7ba;font-size:13px}.timer-controls{display:flex;justify-content:center;flex-wrap:wrap;gap:10px;padding:19px 20px calc(19px + env(safe-area-inset-bottom));border-top:1px solid #3a4258}.control-button{min-height:48px;padding:0 20px;color:#fff;background:#2b344a;border:1px solid #4a5368;font-weight:850}.control-button.primary{min-width:150px;color:var(--ink);background:#fff;border-color:#fff}.control-button.finish{color:#fff;background:var(--green);border-color:var(--green)}.control-button.ghost{color:#bbc1d1;background:transparent}.control-button:hover{border-color:var(--coral)}.feature-strip{display:grid;grid-template-columns:repeat(3,1fr);margin-top:34px;background:rgba(255,254,249,.86);border:1px solid var(--line)}.feature-strip article{display:flex;gap:14px;padding:22px}.feature-strip article+article{border-left:1px solid var(--line)}.feature-strip article>span{color:var(--coral);font:900 11px/1 ui-monospace,monospace}.feature-strip strong{font-size:13px}.feature-strip p{margin:5px 0 0;color:var(--muted);font-size:11px;line-height:1.55}footer{margin-top:28px;padding:22px 0 0;color:var(--muted);border-top:2px solid var(--ink);font:10px/1.5 ui-monospace,monospace;letter-spacing:.08em;text-align:center}footer span{padding:0 8px}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}body.timer-running{overflow:hidden}
.panel-heading{display:flex;align-items:center;gap:10px}.panel-heading span{line-height:24px}.help-button{width:24px;height:24px;flex:0 0 auto;display:grid;place-items:center;padding:0;color:var(--purple);background:#fff;border:1px solid color-mix(in srgb,var(--purple) 48%,var(--line));border-radius:50%;font:900 12px/1 ui-monospace,monospace}.help-button:hover{color:#fff;background:var(--purple)}.help-dialog{width:min(440px,calc(100% - 32px));padding:0;color:var(--ink);background:var(--card);border:1px solid var(--line);border-top:7px solid var(--purple);box-shadow:7px 7px 0 rgba(23,30,52,.18)}.help-dialog::backdrop{background:rgba(23,30,52,.45)}.help-dialog form{padding:22px 24px 24px}.help-dialog-head{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:14px}.help-dialog h3{margin:0;font-size:18px;font-weight:900}.help-close{width:34px;height:34px;padding:0;color:var(--ink);background:transparent;border:1px solid var(--line);font-size:18px;line-height:1}.help-close:hover{border-color:var(--purple)}.help-dialog p{margin:0;color:#4a4f62;font-size:13px;line-height:1.7}.help-dialog .help-setting{margin-bottom:12px;padding:10px 12px;color:var(--ink);background:#fff;border-left:5px solid var(--purple);font-weight:800}.help-dialog ul{margin:0 0 12px;padding-left:20px;font-size:13px;font-weight:750;line-height:1.8}
body.timer-running{background:var(--ink)}body.timer-running main{min-height:0;padding-bottom:0}body.timer-running .timer-view{height:100vh;height:100dvh;min-height:0;margin:0;border:0}
.timer-controls{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));padding-inline:max(12px,calc((100% - 560px)/2))}#timer-view .control-button{min-width:0;padding-inline:10px;white-space:nowrap}.timer-controls .finish{grid-column:1/-1}@media(max-width:360px){#timer-view .control-button{padding-inline:6px;font-size:14px}}@media(orientation:landscape) and (max-height:620px){.timer-stage .timer-clock{font-size:min(24vh,160px)}}
.timer-controls .share{grid-column:1/-1}.control-button.share{color:#fff;background:var(--coral);border-color:var(--coral)}.timer-stage[data-phase=done] .timer-phase{color:#56b99a}.timer-stage[data-phase=done] .progress-track span{background:#56b99a}#wake-status{font-variant-numeric:tabular-nums}#wake-status.wake-warning{margin:-4px -8px;padding:4px 8px;color:#fff;background:#ff2d55;box-shadow:0 0 14px rgba(255,45,85,.7)}.warning-dialog{border-top-color:#ff2d55}.dialog-button{width:100%;min-height:46px;margin-top:16px;color:#fff;background:var(--ink);border:1px solid var(--ink);font-weight:900}.dialog-button:hover{background:var(--coral);border-color:var(--coral)}.dialog-button.ghost{color:var(--ink);background:transparent}.dialog-button.ghost:hover{color:#fff;background:var(--coral)}.help-dialog label{display:block;color:var(--ink);font-size:14px}.share-input{width:100%;height:50px;margin-top:9px;padding:0 13px;color:var(--ink);background:#fff;border:1px solid #bfc0c4;border-radius:0;font-size:16px;font-weight:800}.share-preview{display:block;width:100%;height:auto;background:repeating-conic-gradient(#d8d6cf 0 25%,#f3f1ea 0 50%) 0 0/24px 24px;border:1px solid var(--line)}.help-dialog .share-preview-text{margin-top:12px;color:var(--ink);font-weight:800;white-space:pre-line}.share-actions{display:grid;grid-template-columns:1fr 1fr;gap:8px}.share-actions .dialog-button{margin-top:12px}.share-actions .wide{grid-column:1/-1;margin-top:0}.help-dialog .share-status{min-height:22px;margin-top:8px;color:var(--green);font-weight:800}
@media(max-width:800px){.site-header,.hero,.tool-card,.feature-strip,footer{width:calc(100% - 32px)}.hero{padding:42px 0 32px}.hero-grid{grid-template-columns:1fr;gap:30px}.lede{font-size:14px}.section-heading{padding:25px 20px}.mode-picker{padding:0 20px 24px}.mode-grid{grid-template-columns:1fr 1fr}.settings-layout{grid-template-columns:1fr}.settings-panel{border-right:0;border-bottom:1px solid var(--line)}.settings-panel,.start-panel{padding:24px 20px}.feature-strip{grid-template-columns:1fr}.feature-strip article+article{border-left:0;border-top:1px solid var(--line)}.timer-clock{font-size:clamp(80px,25vw,170px)}}
@media(max-width:480px){.site-header{padding:12px 0 0}.status-pill{font-size:0}.status-pill i{width:9px;height:9px}.hero{padding:16px 0 18px}.eyebrow{margin-bottom:10px;font-size:10px}.hero-grid{gap:12px}h1{font-size:36px}h1 em{-webkit-text-stroke-width:1.5px;text-shadow:3px 3px 0 rgba(23,30,52,.1)}.lede{margin:0;padding:3px 0 3px 16px;border-left-width:4px;font-size:13px;line-height:1.6}.mode-grid{grid-template-columns:1fr}.mode-option span{padding:14px}.field-trio{grid-template-columns:1fr 1fr}.field-trio>div:last-child{grid-column:1/-1}.timer-view{min-height:100dvh;margin:0;border:0}.timer-topline{padding:15px 16px}.timer-stage{padding:16px}.timer-clock{font-size:clamp(72px,26vw,124px)}.timer-controls{padding-inline:12px}.control-button{padding-inline:14px}.control-button.primary{min-width:120px}}
@media(max-width:480px){.sound-controls{gap:6px}.volume-label{position:absolute;width:1px;height:1px;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap}.volume-stepper{margin-left:auto}.volume-stepper button{width:30px}.volume-stepper input[type=number]{width:32px}.test-sound-button{padding:0 10px}}
@media(max-width:340px){.sound-controls{gap:4px}.volume-stepper button{width:28px}.volume-stepper span{padding-right:2px}}
@media(orientation:landscape) and (max-height:620px){.timer-stage{padding:10px}.timer-phase{font-size:22px}.timer-clock{font-size:min(34vh,180px)}.progress-track{margin:14px 0 12px}.round-display{font-size:20px}.next-display{margin-top:4px}.timer-controls{padding-top:10px;padding-bottom:calc(10px + env(safe-area-inset-bottom))}.control-button{min-height:42px}}
@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important;transition:none!important}}
EOF

cat > "$project_dir/src/app.js" <<'EOF'
import { createPlan, cueAt, displaySeconds, formatClock, shareText, snapshotAt, summarizeRun } from './timer-core.mjs';
import { formatTimeOfDay, msUntilNextSecond, restoreRun, resumeAudio, serializeRun } from './run-state.mjs';
import { isBatteryLow } from './device.mjs';

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
      setting: '總輪數 8 輪 · 動作 20 秒／休息 10 秒（共 4 分鐘）',
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
  if (config.mode === 'amrap' && config.duration < 60) return '訓練時間至少 1 分鐘。';
  if (config.mode === 'fortime' && config.cap < 30) return '時間上限至少 30 秒。';
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

window.addEventListener('beforeinstallprompt', (event) => {
  event.preventDefault();
  installPrompt = event;
  $('#install-button').hidden = false;
});
$('#install-button').addEventListener('click', async () => {
  if (!installPrompt) return;
  await installPrompt.prompt();
  installPrompt = null;
  $('#install-button').hidden = true;
});

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

cat > "$project_dir/public/sw.js" <<'EOF'
const CACHE_NAME = 'box-clock-v21';
const APP_SHELL = ['./', './index.html', './styles.css', './app.js', './timer-core.mjs', './run-state.mjs', './device.mjs', './timer-worker.js', './manifest.webmanifest', './icon.svg', './icon-maskable.svg', './apple-touch-icon.png'];

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
  assert.deepEqual(normalizeConfig({ mode: 'emom', prep: 99, rounds: 0, interval: 2 }), { mode: 'emom', prep: 10, rounds: 10, interval: 60 });
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

test('For Time accepts a cap as short as 30 seconds', () => {
  assert.equal(normalizeConfig({ mode: 'fortime', prep: 0, cap: 30 }).cap, 30);
  assert.equal(normalizeConfig({ mode: 'fortime', prep: 0, cap: 29 }).cap, 1200);
  assert.equal(normalizeConfig({ mode: 'fortime', prep: 0, cap: 0 }).cap, 1200);
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
import { isBatteryLow } from '../src/device.mjs';

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
EOF

cat > "$project_dir/README.md" <<'EOF'
# BOX CLOCK

為 CrossFit 與功能性體能訓練設計的單頁間歇計時器。支援 AMRAP、EMOM、Tabata、For Time，沒有帳號、廣告、追蹤或訓練紀錄。

線上版：<https://box-clock.jlab-app.cloud>

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
