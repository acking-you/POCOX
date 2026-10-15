part of '../app_session_screen.dart';

/// The state of the shown view's native settings reads (see
/// [_SessionNativeSettings]).
class _NativeSettingsReads {
  /// What the read in flight is for, or null when none is.
  Object? pending;

  /// Another read was asked for while [pending] ran: its answer may be
  /// older than that request, so one more read follows it.
  bool again = false;

  /// What the shown settings were read for.
  Object? shown;

  /// The project defaults of the draft [shown] names, under its choices.
  SessionSettings? base;
}

/// Settings of an engine that reads them from its host (native OpenCode:
/// catalogs over HTTP) are read asynchronously, so a slow host never holds
/// the UI. ACP agents keep their cached, synchronous state.
///
/// A read belongs to the session or draft, project, connection and
/// capabilities current when it began: an answer for anything else is
/// dropped. Requests made while a read runs coalesce into one following
/// read. Settings read for another session, draft or project are never
/// offered meanwhile; a refresh of the same one keeps what is shown, so the
/// menus and the composer stay usable while it runs.
extension _SessionNativeSettings on _AppSessionState {
  /// Whether this view's settings are read from the host asynchronously.
  bool get _readsNativeSettings =>
      _caps.sessionConfig && (_caps.isOpenCode || _editsDraftOptions);

  /// What the shown view's settings depend on, or null when it has none:
  /// the session or draft (and the draft's project), its load, the host
  /// connection and generation. A capability re-read of the same host is
  /// not a change, so it does not hide what is shown.
  Object? _nativeSettingsKey() {
    final target = _agentTarget();
    if (target == null) return null;
    // A session the host deleted has no settings to read.
    if (_isDeleted(target.thread)) return null;
    final draft = _agentSessionThread == null;
    return (
      target.service,
      target.thread,
      target.load,
      target.link,
      _linkEpoch,
      _caps.generation,
      draft ? _draft.project : null,
    );
  }

  /// Read the shown view's settings again (see the extension).
  void _readNativeSettings() {
    if (!mounted) return;
    final reads = _nativeSettings;
    final key = _nativeSettingsKey();
    if (key == null) {
      reads
        ..pending = null
        ..shown = null
        ..base = null;
      if (_agentSettings != null) _updateState(() => _agentSettings = null);
      return;
    }
    if (reads.pending == key) {
      reads.again = true;
      return;
    }
    reads
      ..pending = key
      ..again = false;
    if (reads.shown != key) {
      reads
        ..shown = null
        ..base = null;
      if (_agentSettings != null) _updateState(() => _agentSettings = null);
    }
    final tid = _agentSessionThread;
    final api = ref.read(bridgeApiProvider);
    final read = tid == null
        ? api.appDraftSessionSettings(widget.serviceKey, _draft.project)
        : api.appSessionSettingsRefresh(widget.serviceKey, tid);
    unawaited(
      read.then(
        (settings) => _nativeSettingsRead(key, settings, draft: tid == null),
        onError: (Object _) => _nativeSettingsRead(key, null, failed: true),
      ),
    );
  }

  void _nativeSettingsRead(
    Object key,
    SessionSettings? settings, {
    bool draft = false,
    bool failed = false,
  }) {
    final reads = _nativeSettings;
    if (!mounted || reads.pending != key) return;
    reads.pending = null;
    if (reads.again || _nativeSettingsKey() != key) {
      _readNativeSettings();
      return;
    }
    // A failed read keeps what is shown; the next refresh asks again.
    if (failed) return;
    reads
      ..shown = key
      ..base = draft ? settings : null;
    _updateState(() => _agentSettings = draft ? _draftSettings() : settings);
  }

  /// The project defaults the shown draft's options were read with, or null
  /// while they are being read.
  SessionSettings? _draftBase() {
    final reads = _nativeSettings;
    return reads.shown != null && reads.shown == _nativeSettingsKey()
        ? reads.base
        : null;
  }
}
