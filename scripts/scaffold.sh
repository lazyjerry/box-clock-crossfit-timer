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
  return { mode, prep, cap: clampInteger(raw.cap, 60, 99 * 60 + 59, MODE_DEFAULTS.fortime.cap) };
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
EOF

cat > "$project_dir/src/timer-worker.js" <<'EOF'
import { createPlan, snapshotAt } from './timer-core.mjs';

let plan = null;
let startedAt = 0;
let pausedAt = 0;
let pausedTotal = 0;
let tickHandle = null;
let running = false;
let paused = false;

const now = () => performance.now();

function currentElapsed(at = now()) {
  if (!plan) return 0;
  const effectiveNow = paused ? pausedAt : at;
  return Math.max(0, effectiveNow - startedAt - pausedTotal);
}

function emit(type = 'tick') {
  if (!plan) return;
  const snapshot = snapshotAt(plan, currentElapsed());
  self.postMessage({ type: snapshot.complete ? 'complete' : type, snapshot, plan });
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
    startedAt = now();
    pausedAt = 0;
    pausedTotal = 0;
    running = true;
    paused = false;
    emit('started');
    startLoop();
  } else if (data.type === 'pause' && running && !paused) {
    pausedAt = now();
    paused = true;
    stopLoop();
    emit('paused');
  } else if (data.type === 'resume' && running && paused) {
    pausedTotal += now() - pausedAt;
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
  <link rel="stylesheet" href="./styles.css">
</head>
<body>
  <main id="top">
    <header class="site-header">
      <a class="brand" href="#top" aria-label="BOX CLOCK 首頁"><span class="brand-mark">BC</span><span>BOX CLOCK</span></a>
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
            <label class="mode-option"><input type="radio" name="mode" value="amrap" checked><span><strong>AMRAP</strong><small>固定時間內完成最多輪</small></span></label>
            <label class="mode-option"><input type="radio" name="mode" value="emom"><span><strong>EMOM</strong><small>每個間隔開始一輪</small></span></label>
            <label class="mode-option"><input type="radio" name="mode" value="tabata"><span><strong>TABATA</strong><small>動作與休息交替</small></span></label>
            <label class="mode-option"><input type="radio" name="mode" value="fortime"><span><strong>FOR TIME</strong><small>正數計時，完成就停止</small></span></label>
          </div>
        </fieldset>

        <div class="settings-layout">
          <section class="settings-panel" aria-labelledby="time-settings-title">
            <div class="panel-title"><span>時間設定</span><small id="mode-description">固定倒數，在時間內完成最多輪數或次數。</small></div>

            <div class="mode-settings" data-mode="amrap">
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

            <div class="mode-settings" data-mode="fortime" hidden>
              <div class="time-field"><label for="fortime-minutes">時間上限</label><div><input id="fortime-minutes" name="fortimeMinutes" type="number" min="1" max="99" value="20" inputmode="numeric" required><span>分</span><input id="fortime-seconds" name="fortimeSeconds" type="number" min="0" max="59" value="0" inputmode="numeric" aria-label="For Time 秒數" required><span>秒</span></div></div>
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
              <div class="sound-toggle">
                <div class="sound-copy"><strong>聲音提示</strong><small>倒數、切換與完訓音效</small></div>
                <label class="sound-switch" for="sound-enabled">
                  <input id="sound-enabled" type="checkbox" checked>
                  <span class="sound-switch-track" aria-hidden="true"><span></span></span>
                  <span id="sound-enabled-label" class="sound-switch-label">開啟</span>
                </label>
              </div>
              <div class="volume-row">
                <div class="volume-heading"><label for="sound-volume">提示音量</label><output id="sound-volume-value" for="sound-volume">70%</output></div>
                <input id="sound-volume" type="range" min="20" max="100" step="5" value="70" aria-describedby="sound-test-status">
              </div>
              <div class="sound-test-row">
                <button id="test-sound-button" class="test-sound-button" type="button">播放測試音</button>
                <p id="sound-test-status" aria-live="polite">測試音不受開關影響</p>
              </div>
            </div>
            <output id="workout-summary" class="workout-summary" aria-live="polite"></output>
            <p id="form-error" class="form-error" role="alert"></p>
            <button class="primary-button" type="submit">開始訓練 <span>→</span></button>
          </aside>
        </div>
      </form>
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
        <button id="pause-button" class="control-button primary" type="button">暫停</button>
        <button id="finish-button" class="control-button finish" type="button" hidden>完成</button>
        <button id="sound-button" class="control-button icon" type="button" aria-pressed="false" aria-label="關閉聲音">聲音 ON</button>
        <button id="fullscreen-button" class="control-button icon" type="button">全螢幕</button>
        <button id="cancel-button" class="control-button ghost" type="button">結束並返回</button>
      </div>
      <p id="timer-live" class="sr-only" aria-live="assertive"></p>
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
.sound-settings{margin-bottom:22px}.sound-toggle{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:16px;padding-bottom:16px;border-bottom:1px solid var(--line)}.sound-copy strong,.sound-copy small{display:block}.sound-copy strong{color:var(--ink);font-size:13px}.sound-copy small{margin-top:4px;color:var(--muted);font-size:11px}.sound-switch{display:flex;align-items:center;gap:9px;min-height:32px;color:var(--ink);font-size:12px;font-weight:850;cursor:pointer}.sound-switch input{position:absolute;opacity:0;pointer-events:none}.sound-switch-track{width:46px;height:26px;display:block;position:relative;flex:0 0 auto;background:#d4d2cc;border:1px solid #aaa8a1;border-radius:13px;transition:.15s}.sound-switch-track>span{width:20px;height:20px;position:absolute;top:2px;left:2px;background:#fff;border:1px solid #aaa8a1;border-radius:50%;box-shadow:1px 1px 0 rgba(23,30,52,.12);transition:.15s}.sound-switch input:checked+.sound-switch-track{background:var(--purple);border-color:var(--purple)}.sound-switch input:checked+.sound-switch-track>span{transform:translateX(20px);border-color:#fff}.sound-switch input:focus-visible+.sound-switch-track{outline:3px solid rgba(118,82,202,.25);outline-offset:3px}.sound-switch-label{min-width:25px}.volume-row{padding:16px 0;border-bottom:1px solid var(--line)}.volume-heading{display:flex;justify-content:space-between;align-items:center;margin-bottom:11px}.volume-heading label{color:var(--ink)}.volume-heading output{min-width:42px;padding:4px 6px;color:#fff;background:var(--purple);font:800 11px/1 ui-monospace,monospace;text-align:center}.volume-row input[type=range]{width:100%;height:8px;margin:0;accent-color:var(--purple);cursor:pointer}.sound-test-row{display:flex;align-items:center;gap:12px;padding-top:16px}.test-sound-button{min-height:40px;padding:0 14px;color:var(--purple);background:#fff;border:1px solid color-mix(in srgb,var(--purple) 48%,var(--line));font-size:12px;font-weight:850}.test-sound-button:hover{color:#fff;background:var(--purple)}.sound-test-row p{margin:0;color:var(--muted);font-size:11px;line-height:1.45}
:root{color-scheme:light;--paper:#f5f3ed;--card:#fffef9;--ink:#171e34;--muted:#707486;--line:#d4d2cc;--coral:#ed735f;--purple:#7652ca;--green:#398a70;--yellow:#e2a62d;--danger:#c6473a;font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans TC",sans-serif}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;color:var(--ink);background:linear-gradient(rgba(23,30,52,.05) 1px,transparent 1px),linear-gradient(90deg,rgba(23,30,52,.05) 1px,transparent 1px),var(--paper);background-size:24px 24px}button,input,select{font:inherit}button{cursor:pointer}button:focus-visible,input:focus-visible,select:focus-visible{outline:3px solid color-mix(in srgb,var(--coral) 35%,transparent);outline-offset:2px}main{min-height:100vh;padding-bottom:34px}.site-header,.hero,.tool-card,.feature-strip,footer{width:min(1180px,calc(100% - 48px));margin-inline:auto}.site-header{padding:28px 0 8px;display:flex;justify-content:space-between;align-items:center;gap:16px}.brand{display:flex;align-items:center;gap:11px;color:var(--ink);text-decoration:none;font:800 11px/1 ui-monospace,monospace;letter-spacing:.18em}.brand-mark{width:34px;height:34px;display:grid;place-items:center;color:#fff;background:var(--coral);border-radius:50%;font-size:9px;letter-spacing:0}.status-pills{display:flex;align-items:center;gap:10px}.status-pill{display:flex;align-items:center;gap:8px;color:var(--muted);font:800 10px/1 ui-monospace,monospace;letter-spacing:.12em}.status-pill i{width:8px;height:8px;background:var(--green);border-radius:50%}.install-button{padding:8px 10px;color:var(--ink);background:transparent;border:1px solid var(--ink);font:800 10px/1 ui-monospace,monospace;letter-spacing:.08em}.hero{padding:58px 0 44px;border-bottom:3px solid var(--ink)}.eyebrow{margin:0 0 18px;color:var(--coral);font:800 12px/1 ui-monospace,monospace;letter-spacing:.22em}.hero-grid{display:grid;grid-template-columns:1.2fr .8fr;align-items:end;gap:56px}h1{margin:0;font-size:clamp(54px,8vw,102px);line-height:.82;letter-spacing:-.065em;font-weight:950}h1 span,h1 em{display:block;font-style:normal}h1 em{color:transparent;-webkit-text-stroke:2px var(--ink);text-shadow:4px 4px 0 rgba(23,30,52,.1)}.lede{margin:0 0 7px;padding:6px 0 6px 22px;border-left:5px solid var(--coral);font-size:16px;font-weight:650;line-height:1.8}.tool-card{margin-top:38px;background:var(--card);border:1px solid var(--line);border-top:7px solid var(--coral);box-shadow:7px 7px 0 rgba(23,30,52,.11)}.section-heading{display:flex;align-items:center;gap:18px;padding:32px}.section-number{width:56px;height:56px;display:grid;place-items:center;flex:0 0 auto;color:#fff;background:var(--coral);border-radius:50%;font:800 14px/1 ui-monospace,monospace}.section-heading h2{margin:0;font-size:clamp(26px,4vw,34px);letter-spacing:-.035em}.section-heading p{margin:6px 0 0;color:var(--muted);font-size:14px}.mode-picker{margin:0;padding:0 32px 32px;border:0}.mode-picker legend{margin-bottom:12px;color:#555a6d;font-size:12px;font-weight:850;letter-spacing:.04em}.mode-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}.mode-option{position:relative;min-width:0}.mode-option input{position:absolute;opacity:0}.mode-option span{height:100%;display:block;padding:18px 16px;background:#f8f7f2;border:1px solid var(--line);transition:.15s}.mode-option strong,.mode-option small{display:block}.mode-option strong{font:900 16px/1 ui-monospace,monospace;letter-spacing:.03em}.mode-option small{margin-top:8px;color:var(--muted);font-size:11px;line-height:1.45}.mode-option input:checked+span{color:#fff;background:var(--ink);border-color:var(--ink);box-shadow:4px 4px 0 var(--coral)}.mode-option input:checked+span small{color:#e4e6ee}.mode-option input:focus-visible+span{outline:3px solid rgba(237,115,95,.3);outline-offset:2px}.settings-layout{display:grid;grid-template-columns:1.15fr .85fr;border-top:1px solid var(--line)}.settings-panel,.start-panel{padding:32px}.settings-panel{background:#faf9f5;border-right:1px solid var(--line)}.start-panel{background:#f1efe8}.panel-title{margin-bottom:26px}.panel-title span,.panel-title small{display:block}.panel-title span{font-size:18px;font-weight:900}.panel-title small{margin-top:6px;color:var(--muted);font-size:12px;line-height:1.5}label{color:#555a6d;font-size:12px;font-weight:800}.time-field>label,.field-pair label,.field-trio label,.start-panel>label{display:block;margin-bottom:9px}.time-field>div{display:grid;grid-template-columns:minmax(0,1fr) auto minmax(0,1fr) auto;align-items:center;gap:10px}.time-field span,.unit-input span{color:var(--muted);font-size:12px;font-weight:800}input[type=number],select{width:100%;height:52px;padding:0 13px;color:var(--ink);background:#fff;border:1px solid #bfc0c4;border-radius:0;font-weight:850;font-variant-numeric:tabular-nums}.field-pair,.field-trio{display:grid;gap:15px}.field-pair{grid-template-columns:1fr 1fr}.field-trio{grid-template-columns:repeat(3,1fr)}.unit-input{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:8px}.quick-presets{margin-top:25px;padding-top:22px;border-top:1px solid var(--line)}.quick-presets>span{display:block;margin-bottom:10px;color:#555a6d;font-size:11px;font-weight:850}.quick-presets>div{display:flex;flex-wrap:wrap;gap:8px}.preset-button{width:auto;min-height:36px;padding:0 13px;color:var(--purple);background:#fff;border:1px solid color-mix(in srgb,var(--purple) 45%,var(--line));font-size:11px;font-weight:850}.preset-button:hover{color:#fff;background:var(--purple)}select{margin-bottom:24px}.toggle-row{display:grid;grid-template-columns:1fr auto;align-items:center;position:relative;margin:0 0 22px;cursor:pointer}.toggle-row strong,.toggle-row small{display:block}.toggle-row strong{color:var(--ink);font-size:13px}.toggle-row small{margin-top:4px;color:var(--muted);font-size:11px}.toggle-row input{position:absolute;opacity:0}.toggle-row i{width:44px;height:24px;position:relative;background:#c9c7c1;border:1px solid #b6b4ae;transition:.15s}.toggle-row i::after{content:"";width:17px;height:17px;position:absolute;top:2px;left:2px;background:#fff;border:1px solid #aaa8a1;transition:.15s}.toggle-row input:checked+i{background:var(--purple);border-color:var(--purple)}.toggle-row input:checked+i::after{transform:translateX(20px);border-color:#fff}.toggle-row input:focus-visible+i{outline:3px solid rgba(118,82,202,.22);outline-offset:2px}.workout-summary{display:block;min-height:72px;margin-bottom:12px;padding:13px 14px;background:#fff;border-left:5px solid var(--purple);font-size:13px;font-weight:750;line-height:1.6}.workout-summary strong{display:block;font-size:17px}.form-error{min-height:19px;margin:0 0 8px;color:var(--danger);font-size:12px;font-weight:750}.primary-button{width:100%;min-height:54px;display:flex;justify-content:space-between;align-items:center;padding:0 18px;color:#fff;background:var(--ink);border:1px solid var(--ink);font-weight:900}.primary-button:hover{background:var(--coral);border-color:var(--coral)}.primary-button span{font-size:20px}.timer-view{min-height:calc(100vh - 32px);margin:16px;background:var(--ink);color:#fff;border:1px solid #3b435b;display:grid;grid-template-rows:auto 1fr auto;overflow:hidden}.timer-view[hidden]{display:none}.timer-topline{display:flex;justify-content:space-between;gap:16px;padding:19px 24px;border-bottom:1px solid #3a4258;color:#bbc1d1;font:800 11px/1 ui-monospace,monospace;letter-spacing:.12em}.timer-stage{display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:0;padding:24px;text-align:center}.timer-phase{margin:0 0 4px;color:var(--coral);font:900 clamp(24px,4vw,48px)/1 ui-monospace,monospace;letter-spacing:.1em}.timer-stage[data-phase=rest] .timer-phase{color:#8b70df}.timer-stage[data-phase=work] .timer-phase,.timer-stage[data-phase=countup] .timer-phase{color:#56b99a}.timer-clock{font:950 clamp(92px,25vw,300px)/.9 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:-.1em;font-variant-numeric:tabular-nums}.progress-track{width:min(680px,86vw);height:9px;margin:34px 0 24px;background:#353e54}.progress-track span{display:block;width:100%;height:100%;background:var(--coral);transform-origin:left center}.timer-stage[data-phase=rest] .progress-track span{background:#8b70df}.timer-stage[data-phase=work] .progress-track span,.timer-stage[data-phase=countup] .progress-track span{background:#56b99a}.round-display{margin:0;font-size:clamp(20px,3vw,36px);font-weight:900}.next-display{margin:9px 0 0;color:#9fa7ba;font-size:13px}.timer-controls{display:flex;justify-content:center;flex-wrap:wrap;gap:10px;padding:19px 20px calc(19px + env(safe-area-inset-bottom));border-top:1px solid #3a4258}.control-button{min-height:48px;padding:0 20px;color:#fff;background:#2b344a;border:1px solid #4a5368;font-weight:850}.control-button.primary{min-width:150px;color:var(--ink);background:#fff;border-color:#fff}.control-button.finish{color:#fff;background:var(--green);border-color:var(--green)}.control-button.ghost{color:#bbc1d1;background:transparent}.control-button:hover{border-color:var(--coral)}.feature-strip{display:grid;grid-template-columns:repeat(3,1fr);margin-top:34px;background:rgba(255,254,249,.86);border:1px solid var(--line)}.feature-strip article{display:flex;gap:14px;padding:22px}.feature-strip article+article{border-left:1px solid var(--line)}.feature-strip article>span{color:var(--coral);font:900 11px/1 ui-monospace,monospace}.feature-strip strong{font-size:13px}.feature-strip p{margin:5px 0 0;color:var(--muted);font-size:11px;line-height:1.55}footer{margin-top:28px;padding:22px 0 0;color:var(--muted);border-top:2px solid var(--ink);font:10px/1.5 ui-monospace,monospace;letter-spacing:.08em;text-align:center}footer span{padding:0 8px}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}body.timer-running{overflow:hidden}
@media(max-width:800px){.site-header,.hero,.tool-card,.feature-strip,footer{width:calc(100% - 32px)}.hero{padding:42px 0 32px}.hero-grid{grid-template-columns:1fr;gap:30px}.lede{font-size:14px}.section-heading{padding:25px 20px}.mode-picker{padding:0 20px 24px}.mode-grid{grid-template-columns:1fr 1fr}.settings-layout{grid-template-columns:1fr}.settings-panel{border-right:0;border-bottom:1px solid var(--line)}.settings-panel,.start-panel{padding:24px 20px}.feature-strip{grid-template-columns:1fr}.feature-strip article+article{border-left:0;border-top:1px solid var(--line)}.timer-clock{font-size:clamp(80px,25vw,170px)}}
@media(max-width:480px){.site-header{padding-top:19px}.status-pill{font-size:0}.status-pill i{width:9px;height:9px}.hero{padding-top:38px}h1{font-size:52px}.mode-grid{grid-template-columns:1fr}.mode-option span{padding:14px}.field-trio{grid-template-columns:1fr 1fr}.field-trio>div:last-child{grid-column:1/-1}.timer-view{min-height:100dvh;margin:0;border:0}.timer-topline{padding:15px 16px}.timer-stage{padding:16px}.timer-clock{font-size:clamp(72px,26vw,124px)}.timer-controls{padding-inline:12px}.control-button{padding-inline:14px}.control-button.primary{min-width:120px}}
@media(orientation:landscape) and (max-height:620px){.timer-stage{padding:10px}.timer-phase{font-size:22px}.timer-clock{font-size:min(34vh,180px)}.progress-track{margin:14px 0 12px}.round-display{font-size:20px}.next-display{margin-top:4px}.timer-controls{padding-top:10px;padding-bottom:calc(10px + env(safe-area-inset-bottom))}.control-button{min-height:42px}}
@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important;transition:none!important}}
EOF

cat > "$project_dir/src/app.js" <<'EOF'
import { createPlan, displaySeconds, formatClock } from './timer-core.mjs';

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const form = $('#timer-form');
const setupView = $('#setup-view');
const timerView = $('#timer-view');
const timerStage = $('.timer-stage');
const worker = new Worker('./timer-worker.js', { type: 'module' });

const MODE_META = {
  amrap: { label: 'AMRAP', description: '固定倒數，在時間內完成最多輪數或次數。' },
  emom: { label: 'EMOM', description: '每個間隔開始新一輪，剩餘時間就是該輪休息。' },
  tabata: { label: 'TABATA', description: '動作與休息交替，預設為經典 20／10 秒 × 8 輪。' },
  fortime: { label: 'FOR TIME', description: '由零開始正數計時；做完按「完成」，或到時間上限自動結束。' }
};

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
    { label: '上限 10 分', values: { fortimeMinutes: 10, fortimeSeconds: 0 } },
    { label: '上限 20 分', values: { fortimeMinutes: 20, fortimeSeconds: 0 } },
    { label: '上限 30 分', values: { fortimeMinutes: 30, fortimeSeconds: 0 } }
  ]
};

let audioContext = null;
let wakeLock = null;
let currentPlan = null;
let currentSnapshot = null;
let currentMode = 'amrap';
let isPaused = false;
let isRunning = false;
let soundEnabled = true;
let soundVolume = 0.7;
let previousPhaseIndex = -1;
let previousCueSecond = null;
let installPrompt = null;

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
  const primaryDuration = config.duration ?? config.cap;
  if ((config.mode === 'amrap' || config.mode === 'fortime') && primaryDuration < 60) return '訓練時間至少 1 分鐘。';
  return '';
}

function summaryText(config) {
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
  const presetContainer = $('#preset-buttons');
  presetContainer.replaceChildren(...PRESETS[currentMode].map((preset) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'preset-button';
    button.textContent = preset.label;
    button.addEventListener('click', () => {
      Object.entries(preset.values).forEach(([name, value]) => { form.elements[name].value = value; });
      updateSummary();
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

async function unlockAudio() {
  if (!audioContext) audioContext = new AudioContext();
  if (audioContext.state === 'suspended') await audioContext.resume();
}

function tone(frequency, duration = 0.12, delay = 0, gain = 0.18, force = false) {
  if ((!soundEnabled && !force) || !audioContext) return;
  const start = audioContext.currentTime + delay;
  const oscillator = audioContext.createOscillator();
  const volume = audioContext.createGain();
  oscillator.type = 'square';
  oscillator.frequency.setValueAtTime(frequency, start);
  volume.gain.setValueAtTime(0.0001, start);
  volume.gain.exponentialRampToValueAtTime(Math.min(gain * soundVolume, 0.28), start + 0.01);
  volume.gain.exponentialRampToValueAtTime(0.0001, start + duration);
  oscillator.connect(volume).connect(audioContext.destination);
  oscillator.start(start);
  oscillator.stop(start + duration + 0.02);
}

function playTransition(kind) {
  if (kind === 'rest') { tone(440, 0.16); tone(330, 0.18, 0.18); }
  else { tone(740, 0.14); tone(980, 0.2, 0.16); }
}

function playComplete() {
  tone(660, 0.16); tone(880, 0.16, 0.2); tone(1100, 0.34, 0.4);
}

function playSoundPreview() {
  tone(523, 0.12, 0, 0.16, true);
  tone(659, 0.12, 0.16, 0.16, true);
  tone(784, 0.24, 0.32, 0.18, true);
}

function updateSoundVolume() {
  soundVolume = Number($('#sound-volume').value) / 100;
  $('#sound-volume-value').value = `${Math.round(soundVolume * 100)}%`;
  $('#sound-volume-value').textContent = `${Math.round(soundVolume * 100)}%`;
}

function updateSoundToggleLabel() {
  const enabled = $('#sound-enabled').checked;
  $('#sound-enabled-label').textContent = enabled ? '開啟' : '關閉';
}

async function requestWakeLock() {
  const status = $('#wake-status');
  if (!('wakeLock' in navigator)) {
    status.textContent = '螢幕常亮：此瀏覽器不支援';
    return;
  }
  try {
    wakeLock = await navigator.wakeLock.request('screen');
    status.textContent = '螢幕常亮：已啟用';
    wakeLock.addEventListener('release', () => {
      wakeLock = null;
      if (isRunning && document.visibilityState === 'visible') status.textContent = '螢幕常亮：已釋放';
    });
  } catch {
    status.textContent = '螢幕常亮：無法啟用';
  }
}

async function releaseWakeLock() {
  if (wakeLock) await wakeLock.release().catch(() => {});
  wakeLock = null;
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
  $('#finish-button').hidden = currentMode !== 'fortime' || phase.kind === 'prepare';

  const cueSecond = displaySeconds(snapshot.phaseRemainingMs);
  if (phase.index !== previousPhaseIndex) {
    if (previousPhaseIndex >= 0) playTransition(phase.kind);
    $('#timer-live').textContent = `${phase.label}${phase.totalRounds > 1 ? `，第 ${phase.round} 輪` : ''}`;
    previousPhaseIndex = phase.index;
    previousCueSecond = null;
  }
  if (!isPaused && cueSecond <= 3 && cueSecond > 0 && cueSecond !== previousCueSecond) {
    tone(cueSecond === 1 ? 920 : 620, 0.13);
    previousCueSecond = cueSecond;
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
  currentMode = config.mode;
  previousPhaseIndex = -1;
  previousCueSecond = null;
  isPaused = false;
  isRunning = true;
  $('#timer-mode').textContent = MODE_META[currentMode].label;
  $('#sound-button').textContent = soundEnabled ? '聲音 ON' : '聲音 OFF';
  $('#sound-button').setAttribute('aria-pressed', String(!soundEnabled));
  $('#sound-button').setAttribute('aria-label', soundEnabled ? '關閉聲音' : '開啟聲音');
  setupView.hidden = true;
  $('.hero').hidden = true;
  $('.site-header').hidden = true;
  $('.feature-strip').hidden = true;
  $('footer').hidden = true;
  timerView.hidden = false;
  document.body.classList.add('timer-running');
  await requestWakeLock();
  worker.postMessage({ type: 'start', config });
}

async function leaveTimer(completed = false) {
  if (isRunning) worker.postMessage({ type: 'stop' });
  isRunning = false;
  isPaused = false;
  await releaseWakeLock();
  timerView.hidden = true;
  setupView.hidden = false;
  $('.hero').hidden = false;
  $('.site-header').hidden = false;
  $('.feature-strip').hidden = false;
  $('footer').hidden = false;
  document.body.classList.remove('timer-running');
  $('#pause-button').textContent = '暫停';
  if (document.fullscreenElement) await document.exitFullscreen().catch(() => {});
  if (completed) {
    $('#form-error').textContent = '訓練完成。';
    $('#form-error').style.color = 'var(--green)';
  } else {
    $('#form-error').textContent = '';
    $('#form-error').style.color = '';
  }
  setupView.scrollIntoView({ block: 'start' });
}

worker.addEventListener('message', ({ data }) => {
  if (data.snapshot) renderSnapshot(data.snapshot);
  if (data.type === 'complete' && isRunning) {
    playComplete();
    $('#timer-live').textContent = '訓練完成';
    leaveTimer(true);
  }
});

form.addEventListener('input', (event) => {
  if (event.target.name === 'mode') updateSetup();
  else updateSummary();
});
form.addEventListener('submit', startWorkout);

$('#pause-button').addEventListener('click', () => {
  isPaused = !isPaused;
  worker.postMessage({ type: isPaused ? 'pause' : 'resume' });
  $('#pause-button').textContent = isPaused ? '繼續' : '暫停';
  $('#timer-live').textContent = isPaused ? '計時已暫停' : '計時繼續';
});
$('#finish-button').addEventListener('click', () => { playComplete(); leaveTimer(true); });
$('#cancel-button').addEventListener('click', () => leaveTimer(false));
$('#sound-button').addEventListener('click', async () => {
  soundEnabled = !soundEnabled;
  if (soundEnabled) { await unlockAudio(); tone(740, 0.12); }
  $('#sound-button').textContent = soundEnabled ? '聲音 ON' : '聲音 OFF';
  $('#sound-button').setAttribute('aria-pressed', String(!soundEnabled));
  $('#sound-button').setAttribute('aria-label', soundEnabled ? '關閉聲音' : '開啟聲音');
});
$('#sound-volume').addEventListener('input', updateSoundVolume);
$('#sound-enabled').addEventListener('change', updateSoundToggleLabel);
$('#test-sound-button').addEventListener('click', async () => {
  try {
    await unlockAudio();
    updateSoundVolume();
    playSoundPreview();
    $('#sound-test-status').textContent = `已播放 ${Math.round(soundVolume * 100)}% 音量的測試音`;
  } catch {
    $('#sound-test-status').textContent = '此瀏覽器無法播放測試音';
  }
});
$('#fullscreen-button').addEventListener('click', async () => {
  if (!document.fullscreenElement) await timerView.requestFullscreen?.();
  else await document.exitFullscreen?.();
});

document.addEventListener('visibilitychange', async () => {
  if (document.visibilityState === 'visible' && isRunning) {
    if (!wakeLock) await requestWakeLock();
    worker.postMessage({ type: 'sync' });
  }
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
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    if (!serviceWorkerRefreshPending) {
      serviceWorkerRefreshPending = true;
      window.location.reload();
    }
  });
  window.addEventListener('load', () => navigator.serviceWorker.register('./sw.js').then((registration) => registration.update()));
}
updateSoundToggleLabel();
updateSetup();
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
    { "src": "./icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any maskable" }
  ]
}
EOF

cat > "$project_dir/public/icon.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect width="512" height="512" rx="92" fill="#171e34"/>
  <path d="M78 92h356v328H78z" fill="#f5f3ed"/>
  <path d="M78 92h356v34H78z" fill="#ed735f"/>
  <text x="256" y="290" text-anchor="middle" font-family="Arial,sans-serif" font-size="126" font-weight="900" fill="#171e34">BC</text>
  <path d="M130 336h252v22H130z" fill="#7652ca"/>
</svg>
EOF

cat > "$project_dir/public/sw.js" <<'EOF'
const CACHE_NAME = 'box-clock-v4';
const APP_SHELL = ['./', './index.html', './styles.css', './app.js', './timer-core.mjs', './timer-worker.js', './manifest.webmanifest', './icon.svg'];

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
import { createPlan, displaySeconds, formatClock, normalizeConfig, snapshotAt } from '../src/timer-core.mjs';

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
EOF

cat > "$project_dir/README.md" <<'EOF'
# BOX CLOCK

為 CrossFit 與功能性體能訓練設計的單頁間歇計時器。支援 AMRAP、EMOM、Tabata、For Time，沒有帳號、廣告、追蹤或訓練紀錄。

## 功能

- Web Worker 以單調時鐘校正經過時間，避免每秒遞減造成累積誤差。
- AMRAP、EMOM、Tabata、For Time 四種原生流程。
- 準備倒數、最後 3 秒、階段切換與完訓聲音提示，可調整音量並播放測試音。
- Screen Wake Lock API 讓支援的瀏覽器在計時中保持螢幕常亮。
- PWA 應用程式殼層離線快取，可安裝至主畫面。
- 行動裝置、橫向顯示、鍵盤操作與螢幕閱讀器狀態提示。

## 隱私

所有設定與計時都在瀏覽器中執行，不送出、不保存，也沒有第三方分析程式。

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

- `src/`：頁面、樣式、互動、Web Worker 與計時核心。
- `public/`：PWA manifest、Service Worker 與圖示。
- `tests/`：計時狀態與邊界測試。
- `scripts/`：專案產生、建置、驗證與發布流程。
EOF

cat > "$project_dir/.gitignore" <<'EOF'
dist/
.wrangler/
.DS_Store
EOF

printf 'Project files generated in %s\n' "$project_dir"
