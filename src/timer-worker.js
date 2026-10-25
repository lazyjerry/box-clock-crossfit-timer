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
