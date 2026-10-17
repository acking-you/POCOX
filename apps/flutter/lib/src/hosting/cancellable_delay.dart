import 'dart:async';

/// One pending wait at a time, which its owner can cut short: [wait]
/// answers `true` once its time passed and `false` when [stop] (or the next
/// [wait]) ended it first, so no timer outlives the operation or page that
/// waits.
class CancellableDelay {
  Timer? _timer;
  Completer<bool>? _pending;

  /// Wait [duration], ending any earlier wait as stopped.
  Future<bool> wait(Duration duration) {
    stop();
    final pending = Completer<bool>();
    _pending = pending;
    _timer = Timer(duration, () {
      if (identical(_pending, pending)) {
        _pending = null;
        _timer = null;
      }
      pending.complete(true);
    });
    return pending.future;
  }

  /// End the pending wait, if any, as stopped.
  void stop() {
    _timer?.cancel();
    _timer = null;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
  }
}
