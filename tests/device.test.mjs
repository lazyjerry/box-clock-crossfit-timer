import test from 'node:test';
import assert from 'node:assert/strict';
import { installButtonAction, installPlatform, isBatteryLow } from '../src/device.mjs';

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

test('install button is hidden when already running as an installed app', () => {
  assert.equal(installButtonAction({ standalone: true, hasPrompt: false }), 'hidden');
  assert.equal(installButtonAction({ standalone: true, hasPrompt: true }), 'hidden');
});

test('install button prompts when the browser offers one-tap install', () => {
  assert.equal(installButtonAction({ standalone: false, hasPrompt: true }), 'prompt');
});

test('install button opens the guide when the browser has no install prompt', () => {
  assert.equal(installButtonAction({ standalone: false, hasPrompt: false }), 'guide');
});

test('iPhone and iPad user agents use the iOS install guide', () => {
  assert.equal(installPlatform({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1', maxTouchPoints: 5 }), 'ios');
  assert.equal(installPlatform({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0.7390.41 Mobile/15E148 Safari/604.1', maxTouchPoints: 5 }), 'ios');
  assert.equal(installPlatform({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15', maxTouchPoints: 5 }), 'ios');
});

test('Android user agents use the Android install guide', () => {
  assert.equal(installPlatform({ userAgent: 'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36', maxTouchPoints: 5 }), 'android');
});

test('desktop user agents use the desktop install guide', () => {
  assert.equal(installPlatform({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15', maxTouchPoints: 0 }), 'desktop');
  assert.equal(installPlatform({ userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36', maxTouchPoints: 0 }), 'desktop');
});
