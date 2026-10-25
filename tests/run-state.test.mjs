import test from 'node:test';
import assert from 'node:assert/strict';
import { createRunClock, formatTimeOfDay, msUntilNextSecond, restoreRun, resumeAudio, serializeRun } from '../src/run-state.mjs';

function fakeNow(start = 1000) {
  let value = start;
  const now = () => value;
  now.advance = (ms) => { value += ms; };
  return now;
}

test('run clock excludes paused time from elapsed', () => {
  const now = fakeNow();
  const clock = createRunClock(now);
  clock.start();
  now.advance(5000);
  clock.pause();
  now.advance(60000);
  assert.equal(clock.elapsed(), 5000);
  clock.resume();
  now.advance(2000);
  assert.equal(clock.elapsed(), 7000);
});

test('run clock restarts paused at a saved elapsed time', () => {
  const now = fakeNow();
  const clock = createRunClock(now);
  clock.start({ elapsedMs: 42000, paused: true });
  now.advance(3600000);
  assert.equal(clock.elapsed(), 42000);
  clock.resume();
  now.advance(1000);
  assert.equal(clock.elapsed(), 43000);
});

test('a saved run restores its config and paused elapsed time', () => {
  const config = { mode: 'tabata', prep: 10, rounds: 8, work: 20, rest: 10 };
  const text = serializeRun({ config, elapsedMs: 95000 });
  assert.deepEqual(restoreRun(text), { config: { mode: 'tabata', prep: 10, rounds: 8, work: 20, rest: 10 }, elapsedMs: 95000 });
});

test('unusable saved runs restore as nothing', () => {
  assert.equal(restoreRun(null), null);
  assert.equal(restoreRun('{broken'), null);
  assert.equal(restoreRun('42'), null);
  assert.equal(restoreRun('{"config":{"mode":"amrap","prep":0,"duration":600},"elapsedMs":-1}'), null);
  assert.equal(restoreRun('{"config":{"mode":"amrap","prep":0,"duration":600},"elapsedMs":"abc"}'), null);
  assert.equal(restoreRun('{"config":{"mode":"yoga","prep":0},"elapsedMs":1000}'), null);
  assert.equal(restoreRun('{"elapsedMs":1000}'), null);
});

test('a saved run that already reached its total duration restores as nothing', () => {
  const config = { mode: 'amrap', prep: 0, duration: 600 };
  assert.equal(restoreRun(serializeRun({ config, elapsedMs: 600000 })), null);
  assert.equal(restoreRun(serializeRun({ config, elapsedMs: 599999 })).elapsedMs, 599999);
});

function fakeAudioContext(state, { rejects = false } = {}) {
  const context = {
    state,
    resumeCalls: 0,
    async resume() {
      context.resumeCalls += 1;
      if (rejects) throw new Error('blocked');
      context.state = 'running';
    }
  };
  return context;
}

test('audio interrupted while away is resumed', async () => {
  const context = fakeAudioContext('interrupted');
  assert.equal(await resumeAudio(context), true);
  assert.equal(context.state, 'running');
});

test('audio that cannot resume reports false instead of throwing', async () => {
  assert.equal(await resumeAudio(fakeAudioContext('suspended', { rejects: true })), false);
  assert.equal(await resumeAudio(null), false);
});

test('time of day shows hours, minutes and seconds', () => {
  assert.equal(formatTimeOfDay(new Date(2026, 9, 25, 14, 20, 5)), '14:20:05');
  assert.equal(formatTimeOfDay(new Date(2026, 9, 25, 9, 3, 59)), '09:03:59');
});

test('wall clock waits until the next whole second', () => {
  assert.equal(msUntilNextSecond(1761373205250), 750);
  assert.equal(msUntilNextSecond(1761373205999), 1);
  assert.equal(msUntilNextSecond(1761373206000), 1000);
});
