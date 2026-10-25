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
