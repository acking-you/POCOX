part of '../bridge_api_rust.dart';

class _NativeComposerControl extends ComposerControl {
  final frb.ComposerController _native = frb.composerCreate();
  ComposerSnapshot _state = ComposerSnapshot();
  @override
  ComposerSnapshot get state => _state;

  @override
  void apply(ComposerAction action, {int? id, int? token}) {
    final next = frb.composerApply(
      controller: _native,
      action: action,
      id: id,
      token: token,
    );
    _state = ComposerSnapshot(
      sendToken: next.sendToken,
      admission: next.admission,
      paused: next.queuePaused,
      queue: [
        for (final entry in next.queue)
          QueuedCommandState(
            entry.id,
            inFlight: entry.inFlight,
            uncertain: entry.uncertain,
          ),
      ],
    );
  }
}
