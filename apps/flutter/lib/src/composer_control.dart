import 'package:pocox/src/rust/api/bridge/composer.dart' show ComposerAction;
export 'package:pocox/src/rust/api/bridge/composer.dart' show ComposerAction;

/// A presentation snapshot of native queue admission, without message bodies.
class QueuedCommandState {
  const QueuedCommandState(
    this.id, {
    this.inFlight = false,
    this.uncertain = false,
  });
  final int id;
  final bool inFlight;
  final bool uncertain;
}

class ComposerSnapshot {
  ComposerSnapshot({
    this.sendToken,
    this.admission = 0,
    this.paused = false,
    List<QueuedCommandState> queue = const [],
  }) : queue = List.unmodifiable(queue),
       byId = {for (final entry in queue) entry.id: entry};
  final int? sendToken;
  final int admission;
  final bool paused;
  final List<QueuedCommandState> queue;
  final Map<int, QueuedCommandState> byId;
}

/// UI adapters cache only the latest native snapshot. All command ordering,
/// lease ownership and unknown-outcome transitions happen in the controller.
abstract class ComposerControl {
  ComposerSnapshot get state;
  void apply(ComposerAction action, {int? id, int? token});
  int beginSend() {
    apply(ComposerAction.beginSend);
    return state.sendToken!;
  }

  void finishSend(int token) => apply(ComposerAction.endSend, token: token);
}
