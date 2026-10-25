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
