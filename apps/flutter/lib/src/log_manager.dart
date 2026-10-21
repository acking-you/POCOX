import 'package:pocox/src/bridge_api.dart';

/// App-wide access to native diagnostics. Rust owns retention and filtering;
/// only an open viewer subscribes and retains its current display snapshot.
class LogManager {
  LogManager._();
  static final LogManager instance = LogManager._();
  static const levels = ['TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR'];
  BridgeApi? _api;

  void initialize(BridgeApi api) => _api ??= api;
  void dispose() => _api = null;

  Stream<void> get changes => _api?.logChanges() ?? const Stream.empty();

  Future<LogView> query({String? level, String keyword = ''}) async =>
      await _api?.logQuery(level: level, keyword: keyword) ??
      const LogView(lines: [], total: 0);

  /// Callers must not include credentials or message bodies.
  void record(String target, String message, {String level = 'INFO'}) =>
      _api?.logRecord(target, message, level: level);

  void clear() => _api?.logClear();

  static String normalizeLevel(String level) {
    final normalized = level.trim().toUpperCase();
    return levels.contains(normalized) ? normalized : 'UNKNOWN';
  }

  static String thresholdLabel(String level) {
    final normalized = normalizeLevel(level);
    return normalized == 'ERROR' || normalized == 'UNKNOWN'
        ? normalized
        : '$normalized+';
  }
}
