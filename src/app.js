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
