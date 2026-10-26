import 'dart:math' as math;

/// [bytes] in decimal units, as Finder counts them: `0 B`, `840 B`,
/// `3.2 KB`, `12 MB`. One decimal below ten, whole numbers above.
String formatByteCount(int bytes) {
  if (bytes < 1000) return '${math.max(bytes, 0)} B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1000;
  var unit = 0;
  // 999.5 would print as "1000"; it belongs to the next unit.
  while (value >= 999.5 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = value < 9.95 ? 1 : 0;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// [ms] as a clock: `0:42`, `12:05`, `1:02:09`.
String formatElapsed(int ms) {
  final seconds = math.max(ms, 0) ~/ 1000;
  String two(int v) => v.toString().padLeft(2, '0');
  final h = seconds ~/ 3600;
  final m = seconds ~/ 60 % 60;
  final s = seconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}
