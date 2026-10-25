import test from 'node:test';
import assert from 'node:assert/strict';
import { createPlan, displaySeconds, formatClock, normalizeConfig, shareText, snapshotAt, summarizeRun } from '../src/timer-core.mjs';

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
