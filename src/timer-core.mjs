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
