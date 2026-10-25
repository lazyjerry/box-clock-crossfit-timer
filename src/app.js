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
