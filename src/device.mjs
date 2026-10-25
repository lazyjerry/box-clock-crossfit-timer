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
