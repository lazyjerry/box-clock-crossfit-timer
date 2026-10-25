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

// iOS PWA 從背景回來後，舊的 AudioContext 可能回報 running 卻不出聲；離開畫面就關掉，下次手勢重建。
export function closeAudio(context) {
  try {
    context?.close().catch(() => {});
  } catch {}
}

export function formatTimeOfDay(date) {
  return [date.getHours(), date.getMinutes(), date.getSeconds()].map((part) => String(part).padStart(2, '0')).join(':');
}

export function msUntilNextSecond(epochMs) {
  return 1000 - (epochMs % 1000);
}
