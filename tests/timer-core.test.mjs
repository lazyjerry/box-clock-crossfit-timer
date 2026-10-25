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
  assert.deepEqual(normalizeConfig({ mode: 'emom', prep: 99, rounds: 0, interval: 0 }), { mode: 'emom', prep: 10, rounds: 10, interval: 60 });
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

test('For Time accepts a cap as short as 1 second', () => {
  assert.equal(normalizeConfig({ mode: 'fortime', prep: 0, cap: 1 }).cap, 1);
  assert.equal(normalizeConfig({ mode: 'fortime', prep: 0, cap: 0 }).cap, 1200);
});

test('AMRAP accepts a duration as short as 1 second', () => {
  assert.equal(normalizeConfig({ mode: 'amrap', prep: 0, duration: 1 }).duration, 1);
  assert.equal(normalizeConfig({ mode: 'amrap', prep: 0, duration: 0 }).duration, 720);
});

test('EMOM accepts one round of one second', () => {
  assert.deepEqual(normalizeConfig({ mode: 'emom', prep: 0, rounds: 1, interval: 1 }), { mode: 'emom', prep: 0, rounds: 1, interval: 1 });
  assert.equal(normalizeConfig({ mode: 'emom', prep: 0, rounds: 1, interval: 0 }).interval, 60);
});

test('Tabata accepts one round of one second with no rest', () => {
  assert.deepEqual(normalizeConfig({ mode: 'tabata', prep: 0, rounds: 1, work: 1, rest: 0 }), { mode: 'tabata', prep: 0, rounds: 1, work: 1, rest: 0 });
  assert.equal(normalizeConfig({ mode: 'tabata', prep: 0, rounds: 1, work: 0, rest: 0 }).work, 20);
});
