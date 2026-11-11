export function isBatteryLow(battery) {
  return !battery.charging && battery.level < 0.3;
}

export function installButtonAction({ standalone, hasPrompt }) {
  if (standalone) return 'hidden';
  return hasPrompt ? 'prompt' : 'guide';
}

export function installPlatform({ userAgent = '', maxTouchPoints = 0 }) {
  // iPadOS Safari reports a Mac user agent; touch points tell it apart from a real Mac.
  if (/iPhone|iPad|iPod/.test(userAgent) || (/Macintosh/.test(userAgent) && maxTouchPoints > 1)) return 'ios';
  if (/Android/.test(userAgent)) return 'android';
  return 'desktop';
}

export function localDateKey(date) {
  const pad = (value) => String(value).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

// 「今日不再提醒我」只擋到本機日期換日為止。
export function appPromoVisible({ dismissedOn, now }) {
  return dismissedOn !== localDateKey(now);
}
