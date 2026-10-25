import test from 'node:test';
import assert from 'node:assert/strict';
import { isBatteryLow } from '../src/device.mjs';

test('battery below 30 percent and not charging is low', () => {
  assert.equal(isBatteryLow({ level: 0.29, charging: false }), true);
  assert.equal(isBatteryLow({ level: 0.05, charging: false }), true);
});

test('battery at or above 30 percent is not low', () => {
  assert.equal(isBatteryLow({ level: 0.3, charging: false }), false);
  assert.equal(isBatteryLow({ level: 0.8, charging: false }), false);
});

test('charging battery is not low', () => {
  assert.equal(isBatteryLow({ level: 0.1, charging: true }), false);
});
