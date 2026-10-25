export function isBatteryLow(battery) {
  return !battery.charging && battery.level < 0.3;
}
