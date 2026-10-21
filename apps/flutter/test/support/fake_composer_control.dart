import 'package:pocox/src/composer_control.dart';

/// Memory fixture for widget scenarios. Native transition invariants are tested
/// in composer.rs; this adapter supplies deterministic snapshots without FFI.
class FakeComposerControl extends ComposerControl {
  ComposerSnapshot _state = ComposerSnapshot();
  int _next = 0;
  @override
  ComposerSnapshot get state => _state;
  @override
  void apply(ComposerAction action, {int? id, int? token}) {
    var send = _state.sendToken, generation = _state.admission;
    var paused = _state.paused;
    final queue = [..._state.queue];
    final at = id == null ? -1 : queue.indexWhere((entry) => entry.id == id);
    void flags({bool? inFlight, bool? uncertain}) {
      if (at < 0) return;
      final old = queue[at];
      queue[at] = QueuedCommandState(
        old.id,
        inFlight: inFlight ?? old.inFlight,
        uncertain: uncertain ?? old.uncertain,
      );
    }

    switch (action) {
      case ComposerAction.enqueue:
        queue.add(QueuedCommandState(id!));
      case ComposerAction.prepend:
        queue.insert(0, QueuedCommandState(id!));
      case ComposerAction.drop || ComposerAction.accept:
        if (at >= 0) queue.removeAt(at);
      case ComposerAction.beginSend:
        if (send != null) throw StateError('a send is already pending');
        send = ++_next;
      case ComposerAction.endSend:
        if (send == token) send = null;
      case ComposerAction.pause:
        paused = true;
      case ComposerAction.resume:
        paused = false;
      case ComposerAction.beginQueued:
        if (at != 0 || paused || queue[at].uncertain || queue[at].inFlight) {
          throw StateError('queued command is not ready');
        }
        flags(inFlight: true);
      case ComposerAction.endQueued:
        flags(inFlight: false);
      case ComposerAction.unknown || ComposerAction.refused:
        flags(inFlight: false, uncertain: action == ComposerAction.unknown);
        paused = true;
      case ComposerAction.retryUnknown:
        flags(uncertain: false);
      case ComposerAction.revoke:
        generation++;
    }
    _state = ComposerSnapshot(
      sendToken: send,
      admission: generation,
      paused: paused,
      queue: queue,
    );
  }
}
