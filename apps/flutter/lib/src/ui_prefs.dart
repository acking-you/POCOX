import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show protected, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocket_codex/src/bridge_api.dart' show AcpAgentSpec;

/// Durable, device-local UI preferences backing the chat-first home screen:
/// which app service the user prefers and last talked to, the last-open thread
/// per service, and the parameters of the local host the user left running (so
/// a desktop restart can bring hosting back up without a trip through the
/// manage page).
///
/// Small JSON file in the app-support dir (same pattern as
/// `dismissed_services.json`): survives restarts, never blocks the UI, and a
/// corrupt/unreadable file degrades to defaults rather than crashing.
class UiPrefs {
  /// Creates a prefs snapshot.
  const UiPrefs({
    this.preferredAppServiceKey,
    this.lastServiceKey,
    this.lastThreadByService = const {},
    this.autoHostCodex = const [],
    this.acpAgents = const [],
    this.autoHostAcp = const [],
    this.autoHostOpenCode,
    this.guideSeen = false,
    this.themeMode,
    this.composerHeight,
    this.sidebarOpen,
    this.sidebarWidth,
  });

  /// Custom ACP agents the user saved (program + arguments, in plain text).
  final List<AcpAgentSpec> acpAgents;

  /// The ACP agents the user left hosted, restored on a desktop cold start.
  final List<AutoHostAcpPrefs> autoHostAcp;

  /// The native OpenCode host on OpenCode's default database the user left
  /// running, restored on a desktop cold start (one host serves that
  /// database at a time). Hosts with a history of their own are restored
  /// from the bridge's records only.
  final AutoHostOpenCodePrefs? autoHostOpenCode;

  /// Full relay key of the app service explicitly chosen as the default host.
  final String? preferredAppServiceKey;

  /// Full relay key of the app service the user last chatted on.
  final String? lastServiceKey;

  /// Last-open thread id, keyed by service key.
  final Map<String, String> lastThreadByService;

  /// The Codex hosts the user left running, one record per instance name
  /// (at most [maxAutoHosts]), restored on a desktop cold start. Stopping a
  /// host forgets only its own record.
  final List<AutoHostPrefs> autoHostCodex;

  /// The first Codex auto-host record — the single record older builds kept
  /// (and still read from `autoHost` in the JSON).
  AutoHostPrefs? get autoHost => autoHostCodex.firstOrNull;

  /// Most restore records kept per provider (Codex, ACP). A host started
  /// beyond this still runs but is not restored at the next launch; the
  /// hosting dialog says so instead of silently dropping another record.
  static const maxAutoHosts = 16;

  /// Most saved custom ACP agents.
  static const maxSavedAgents = 50;

  /// Whether the first-run welcome guide has been shown on this device. Set
  /// the first time it renders, so signing in ever again skips it.
  final bool guideSeen;

  /// Explicit theme choice: `'light'` / `'dark'`, or null to follow the
  /// system. A string (not the enum) so the on-disk JSON stays readable and
  /// index-shift-proof.
  final String? themeMode;

  /// Preferred minimum input height; null uses the compact default.
  /// Text can grow the input beyond this height without changing the preference.
  final double? composerHeight;

  /// Whether the desktop sidebar was left open; null means the default (open).
  final bool? sidebarOpen;

  /// The desktop sidebar width the user dragged to; null uses the default.
  final double? sidebarWidth;

  /// Copy with the given fields replaced. `clearThemeMode` returns to
  /// follow-system (a plain null argument means "keep").
  UiPrefs copyWith({
    String? preferredAppServiceKey,
    String? lastServiceKey,
    Map<String, String>? lastThreadByService,
    List<AutoHostPrefs>? autoHostCodex,
    List<AcpAgentSpec>? acpAgents,
    List<AutoHostAcpPrefs>? autoHostAcp,
    AutoHostOpenCodePrefs? autoHostOpenCode,
    bool clearAutoHostOpenCode = false,
    bool? guideSeen,
    String? themeMode,
    bool clearThemeMode = false,
    double? composerHeight,
    bool? sidebarOpen,
    double? sidebarWidth,
  }) => UiPrefs(
    preferredAppServiceKey:
        preferredAppServiceKey ?? this.preferredAppServiceKey,
    lastServiceKey: lastServiceKey ?? this.lastServiceKey,
    lastThreadByService: lastThreadByService ?? this.lastThreadByService,
    autoHostCodex: autoHostCodex ?? this.autoHostCodex,
    acpAgents: acpAgents ?? this.acpAgents,
    autoHostAcp: autoHostAcp ?? this.autoHostAcp,
    autoHostOpenCode: clearAutoHostOpenCode
        ? null
        : (autoHostOpenCode ?? this.autoHostOpenCode),
    guideSeen: guideSeen ?? this.guideSeen,
    themeMode: clearThemeMode ? null : (themeMode ?? this.themeMode),
    composerHeight: composerHeight ?? this.composerHeight,
    sidebarOpen: sidebarOpen ?? this.sidebarOpen,
    sidebarWidth: sidebarWidth ?? this.sidebarWidth,
  );

  /// Parse from JSON; any shape surprise degrades to defaults.
  factory UiPrefs.fromJson(Map<String, dynamic> json) {
    final threads = <String, String>{};
    final rawThreads = json['lastThreadByService'];
    if (rawThreads is Map) {
      rawThreads.forEach((k, v) {
        if (k is String && v is String) threads[k] = v;
      });
    }
    final rawHost = json['autoHost'];
    final rawCodexHosts = json['autoHostCodex'];
    final rawAgents = json['acpAgents'];
    final rawAcpHosts = json['autoHostAcp'];
    return UiPrefs(
      acpAgents: [
        if (rawAgents is List)
          for (final agent in rawAgents.take(maxSavedAgents))
            if (AcpAgentSpec.fromJson(agent) case final spec?
                when !_retiredAcpProfile(spec))
              spec,
      ],
      autoHostAcp: [
        if (rawAcpHosts is List)
          for (final host in rawAcpHosts.take(maxAutoHosts))
            if (AutoHostAcpPrefs.fromJson(host) case final record?
                when !_retiredAcpProfile(record.spec))
              record,
      ],
      autoHostOpenCode: AutoHostOpenCodePrefs.fromJson(
        json['autoHostOpenCode'],
      ),
      preferredAppServiceKey: _as<String>(json['preferredAppServiceKey']),
      lastServiceKey: _as<String>(json['lastServiceKey']),
      lastThreadByService: threads,
      // `autoHostCodex` supersedes the single legacy `autoHost` record; a
      // file written by an older build only has the latter.
      autoHostCodex: rawCodexHosts is List
          ? _uniqueByName([
              for (final host in rawCodexHosts.take(maxAutoHosts))
                if (host is Map<String, dynamic>) AutoHostPrefs.fromJson(host),
            ])
          : [
              if (rawHost is Map<String, dynamic>)
                AutoHostPrefs.fromJson(rawHost),
            ],
      guideSeen: json['guideSeen'] == true,
      themeMode: json['themeMode'] == 'light' || json['themeMode'] == 'dark'
          ? json['themeMode'] as String
          : null,
      composerHeight: switch (json['composerHeight']) {
        num value when value.isFinite => value.toDouble().clamp(28, 280),
        _ => null,
      },
      sidebarOpen: _as<bool>(json['sidebarOpen']),
      sidebarWidth: switch (json['sidebarWidth']) {
        num value when value.isFinite => value.toDouble().clamp(200, 520),
        _ => null,
      },
    );
  }

  /// JSON for persistence.
  Map<String, dynamic> toJson() => {
    if (preferredAppServiceKey != null)
      'preferredAppServiceKey': preferredAppServiceKey,
    if (lastServiceKey != null) 'lastServiceKey': lastServiceKey,
    if (lastThreadByService.isNotEmpty)
      'lastThreadByService': lastThreadByService,
    // The first record also goes under the legacy key, so a downgraded
    // build still restores one host instead of none.
    if (autoHost != null) 'autoHost': autoHost!.toJson(),
    if (autoHostCodex.isNotEmpty)
      'autoHostCodex': [for (final host in autoHostCodex) host.toJson()],
    if (acpAgents.isNotEmpty)
      'acpAgents': [for (final agent in acpAgents) agent.toJson()],
    if (autoHostAcp.isNotEmpty)
      'autoHostAcp': [for (final host in autoHostAcp) host.toJson()],
    if (autoHostOpenCode != null)
      'autoHostOpenCode': autoHostOpenCode!.toJson(),
    if (guideSeen) 'guideSeen': true,
    if (themeMode != null) 'themeMode': themeMode,
    if (composerHeight != null) 'composerHeight': composerHeight,
    if (sidebarOpen != null) 'sidebarOpen': sidebarOpen,
    if (sidebarWidth != null) 'sidebarWidth': sidebarWidth,
  };
}

/// [value] when it is a [T], else null: a field of the wrong shape reads as
/// absent.
T? _as<T>(Object? value) => value is T ? value : null;

/// [items] with [item] replacing any entry of the same [key]; null when
/// [bound] other entries already fill it.
List<T>? _upsert<T>(List<T> items, T item, Object? Function(T) key, int bound) {
  final others = _without(items, key(item), key) ?? items;
  return others.length >= bound ? null : [...others, item];
}

/// [items] without the entries whose [key] is [match]; null when none is.
List<T>? _without<T>(List<T> items, Object? match, Object? Function(T) key) {
  final kept = [
    for (final item in items)
      if (key(item) != match) item,
  ];
  return kept.length == items.length ? null : kept;
}

/// The removed OpenCode ACP preset (`opencode acp`): its records are
/// dropped, never relaunched as a generic agent. OpenCode is hosted natively
/// ([AutoHostOpenCodePrefs]).
bool _retiredAcpProfile(AcpAgentSpec spec) => spec.profileId == 'opencode';

/// [hosts] with later duplicates of a name dropped.
List<AutoHostPrefs> _uniqueByName(List<AutoHostPrefs> hosts) {
  final seen = <String>{};
  return [
    for (final host in hosts)
      if (seen.add(host.name)) host,
  ];
}

/// The `appServeStart` parameters of one Codex host the user started, so a
/// cold start can restore external hosting.
class AutoHostPrefs {
  /// Creates an auto-host record.
  const AutoHostPrefs({
    required this.port,
    required this.name,
    this.proxy,
    this.embedded = false,
    this.binaryOverride,
  });

  /// Listen port passed to `appServeStart` (0 = ephemeral).
  final int port;

  /// Instance name.
  final String name;

  /// Upstream proxy URL, or null when the user turned the proxy off.
  final String? proxy;

  /// Legacy field retained for old records; restored hosts use external Codex.
  final bool embedded;

  /// Explicit codex binary path, when the user customized it.
  final String? binaryOverride;

  /// Parse from JSON; defaults on shape surprises.
  factory AutoHostPrefs.fromJson(Map<String, dynamic> json) => AutoHostPrefs(
    port: _as<int>(json['port']) ?? 0,
    name: _as<String>(json['name']) ?? 'default',
    proxy: _as<String>(json['proxy']),
    binaryOverride: _as<String>(json['binaryOverride']),
  );

  /// JSON for persistence.
  Map<String, dynamic> toJson() => {
    'port': port,
    'name': name,
    if (proxy != null) 'proxy': proxy,
    'embedded': false,
    if (binaryOverride != null) 'binaryOverride': binaryOverride,
  };
}

/// An ACP agent the user left hosted under [name], restored on cold start.
class AutoHostAcpPrefs {
  /// Creates an ACP auto-host record.
  const AutoHostAcpPrefs({required this.name, required this.spec});

  /// Instance name.
  final String name;

  /// What was hosted.
  final AcpAgentSpec spec;

  /// From persisted JSON; `null` when malformed.
  static AutoHostAcpPrefs? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final spec = AcpAgentSpec.fromJson(json['spec']);
    if (name is! String || name.isEmpty || spec == null) return null;
    return AutoHostAcpPrefs(name: name, spec: spec);
  }

  /// JSON for persistence.
  Map<String, dynamic> toJson() => {'name': name, 'spec': spec.toJson()};
}

/// The native OpenCode host the user left running under [name].
class AutoHostOpenCodePrefs {
  /// Creates an OpenCode auto-host record.
  const AutoHostOpenCodePrefs({required this.name, this.binary});

  /// Instance name.
  final String name;

  /// Explicit `opencode` executable, when the user chose one.
  final String? binary;

  /// From persisted JSON; `null` when malformed.
  static AutoHostOpenCodePrefs? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final binary = json['binary'];
    if (name is! String || name.isEmpty) return null;
    return AutoHostOpenCodePrefs(
      name: name,
      binary: binary is String && binary.isNotEmpty ? binary : null,
    );
  }

  /// JSON for persistence.
  Map<String, dynamic> toJson() => {
    'name': name,
    if (binary != null) 'binary': binary,
  };
}

/// One preference change: the next snapshot from [prefs], or null when it
/// changes nothing.
typedef UiPrefsOp = UiPrefs? Function(UiPrefs prefs);

/// Store notifier: load-once, serial best-effort writes (mirrors the
/// robustness contract of [DismissedServices]).
///
/// Every mutation is an operation ([UiPrefsOp]) on the current snapshot.
/// Operations issued before the file has been read are applied to the
/// interim in-memory state and also queued; once the file is read they are
/// replayed, in order, on the loaded snapshot. So a per-name update or
/// removal made during the initial load (stopping host A, starting host B)
/// keeps every other loaded entry and is never undone by the file.
///
/// The provider's `future` resolves on the first non-loading state, which
/// may be such an interim snapshot; [ready] resolves only once the file was
/// read and every queued operation replayed. Bounded records report whether
/// the settled snapshot accepted them (see [setAutoHost]).
class UiPrefsStore extends AsyncNotifier<UiPrefs> {
  File? _cachedFile;
  bool _loaded = false;
  final List<UiPrefsOp> _beforeLoad = [];
  final Completer<void> _ready = Completer<void>();
  // The authoritative snapshot once the file is read. The provider state
  // takes the build result a microtask after build returns; an operation
  // applied in between works on, and is restored from, this snapshot.
  UiPrefs? _settled;
  // Verdicts of operations issued before the load, decided by its replay.
  final List<Completer<bool>> _pendingVerdicts = [];
  Future<void> _writes = Future<void>.value();

  /// Replaces the app-support file lookup (tests: a temporary file whose
  /// lookup can be delayed to hold the initial load open).
  @visibleForTesting
  static Future<File> Function()? debugFileOverride;

  Future<File> _file() async {
    final cached = _cachedFile;
    if (cached != null) return cached;
    final override = debugFileOverride;
    if (override != null) return _cachedFile = await override();
    final dir = await getApplicationSupportDirectory();
    final handle = File('${dir.path}/ui_state.json');
    _cachedFile = handle;
    return handle;
  }

  @override
  Future<UiPrefs> build() async {
    var disposed = false;
    ref.onDispose(() {
      disposed = true;
      // Never replayed, so never stored.
      for (final verdict in _pendingVerdicts) {
        if (!verdict.isCompleted) verdict.complete(false);
      }
      _pendingVerdicts.clear();
    });
    listenSelf((_, next) {
      if (!next.hasValue || identical(next.valueOrNull, _settled)) return;
      // The build result arrived after a newer operation: restore it.
      scheduleMicrotask(() {
        final settled = _settled;
        if (disposed || settled == null) return;
        if (!identical(state.valueOrNull, settled)) state = AsyncData(settled);
      });
    });
    var prefs = await load();
    // A store disposed during the load (container gone) replays and writes
    // nothing; [ready] still resolves, so nothing waits on it forever.
    if (disposed) {
      _settled = prefs;
      if (!_ready.isCompleted) _ready.complete();
      return prefs;
    }
    // Replay runs with the file loaded, so the verdicts it reports (see
    // [_decide]) are taken on the loaded snapshot.
    _loaded = true;
    if (_beforeLoad.isNotEmpty) {
      for (final op in _beforeLoad) {
        prefs = op(prefs) ?? prefs;
      }
      _beforeLoad.clear();
      _enqueueWrite(prefs);
    }
    _pendingVerdicts.clear();
    _settled = prefs;
    if (!_ready.isCompleted) _ready.complete();
    return prefs;
  }

  /// The settled snapshot: the file has been read and every operation
  /// issued before that has been replayed on it (and its write queued).
  Future<UiPrefs> get ready => _ready.future.then((_) => _current);

  /// Reads the persisted snapshot. Tests override it (with [save]) to stay
  /// in memory.
  @protected
  Future<UiPrefs> load() => _load();

  Future<UiPrefs> _load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const UiPrefs();
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return const UiPrefs();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return UiPrefs.fromJson(decoded);
      return const UiPrefs();
    } catch (_) {
      // Corrupt or unreadable prefs must never block the home screen.
      return const UiPrefs();
    }
  }

  /// Persists [prefs]. In-memory test stores override it (with [load]) so
  /// they never touch the app-support file.
  @protected
  Future<void> save(UiPrefs prefs) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(prefs.toJson()));
  }

  void _enqueueWrite(UiPrefs prefs) {
    if (!_loaded) return;
    _writes = _writes.then((_) async {
      try {
        await save(prefs);
      } catch (_) {
        // Best-effort: an unwritable dir just loses the pref, not the app.
      }
    });
  }

  /// Resolves once every write issued so far has finished (tests).
  @visibleForTesting
  Future<void> get debugWritesDone => _writes;

  UiPrefs get _current => _settled ?? state.valueOrNull ?? const UiPrefs();

  /// Apply [op] now, and again on the loaded file if it is not read yet.
  void _mutate(UiPrefsOp op) {
    if (!_loaded) _beforeLoad.add(op);
    final next = op(_current);
    if (next == null) return;
    if (_loaded) _settled = next;
    state = AsyncData(next);
    _enqueueWrite(next);
  }

  /// [_mutate] with [op]'s verdict on the settled snapshot: accepted when it
  /// returns a snapshot, refused when it returns null. An operation issued
  /// before the file is read also runs on the interim state, but only its
  /// replay on the loaded file decides. Ordered with every other operation,
  /// so a later stop still wins over an earlier start.
  Future<bool> _decide(UiPrefsOp op) {
    final verdict = Completer<bool>();
    if (!_loaded) _pendingVerdicts.add(verdict);
    _mutate((p) {
      final next = op(p);
      if (_loaded && !verdict.isCompleted) verdict.complete(next != null);
      return next;
    });
    return verdict.future;
  }

  /// Choose the app service that chat-first home should try before all others.
  void setPreferredAppService(String serviceKey) => _mutate(
    (p) => p.preferredAppServiceKey == serviceKey
        ? null
        : p.copyWith(preferredAppServiceKey: serviceKey),
  );

  /// Record the app service the user is chatting on.
  void setLastService(String serviceKey) =>
      _mutate((p) => p.copyWith(lastServiceKey: serviceKey));

  /// Record the last-open thread for [serviceKey] (null clears it, e.g. when
  /// the user starts a fresh conversation that has no id yet).
  void setLastThread(String serviceKey, String? threadId) => _mutate((p) {
    final threads = {...p.lastThreadByService};
    if (threadId == null) {
      if (threads.remove(serviceKey) == null) return null;
    } else {
      if (threads[serviceKey] == threadId) return null;
      threads[serviceKey] = threadId;
    }
    return p.copyWith(lastThreadByService: threads);
  });

  /// Record that the first-run welcome guide has been shown on this device.
  void markGuideSeen() =>
      _mutate((p) => p.guideSeen ? null : p.copyWith(guideSeen: true));

  /// Remember the Codex host the user just started under `host.name`, for
  /// cold-start restore. Records of other instance names are kept: with
  /// [UiPrefs.maxAutoHosts] others already kept, nothing changes. Resolves
  /// with whether the settled snapshot holds the record.
  Future<bool> setAutoHost(AutoHostPrefs host) => _decide((p) {
    final hosts = _upsert(
      p.autoHostCodex,
      host,
      (h) => h.name,
      UiPrefs.maxAutoHosts,
    );
    return hosts == null ? null : p.copyWith(autoHostCodex: hosts);
  });

  /// Set the theme: `'light'` / `'dark'`, or null to follow the system.
  void setThemeMode(String? mode) => _mutate((p) {
    if (p.themeMode == mode) return null;
    return mode == null
        ? p.copyWith(clearThemeMode: true)
        : p.copyWith(themeMode: mode);
  });

  /// Persist the preferred input height within the supported range.
  void setComposerHeight(double height) {
    if (!height.isFinite) return;
    _mutate((p) => p.copyWith(composerHeight: height.clamp(28, 280)));
  }

  /// Remember whether the desktop sidebar is open.
  void setSidebarOpen(bool open) => _mutate(
    (p) => p.sidebarOpen == open ? null : p.copyWith(sidebarOpen: open),
  );

  /// Persist the desktop sidebar width within the supported range.
  void setSidebarWidth(double width) {
    if (!width.isFinite) return;
    _mutate((p) => p.copyWith(sidebarWidth: width.clamp(200, 520)));
  }

  /// Forget the Codex auto-host record of [name] (the user stopped that host
  /// on purpose). Other hosts keep restoring.
  void clearAutoHost(String name) => _mutate((p) {
    final hosts = _without(p.autoHostCodex, name, (h) => h.name);
    return hosts == null ? null : p.copyWith(autoHostCodex: hosts);
  });

  /// Save (or replace, by profile id) a custom ACP agent. A full list
  /// ([UiPrefs.maxSavedAgents] others) is left as is; resolves with whether
  /// the settled snapshot holds the agent.
  Future<bool> saveAcpAgent(AcpAgentSpec agent) => _decide((p) {
    final agents = _upsert(
      p.acpAgents,
      agent,
      (a) => a.profileId,
      UiPrefs.maxSavedAgents,
    );
    return agents == null ? null : p.copyWith(acpAgents: agents);
  });

  /// Forget a saved custom ACP agent.
  void removeAcpAgent(String profileId) => _mutate((p) {
    final agents = _without(p.acpAgents, profileId, (a) => a.profileId);
    return agents == null ? null : p.copyWith(acpAgents: agents);
  });

  /// Remember an ACP agent the user just hosted under `host.name`; same
  /// bound and verdict as [setAutoHost].
  Future<bool> setAutoHostAcp(AutoHostAcpPrefs host) => _decide((p) {
    final hosts = _upsert(
      p.autoHostAcp,
      host,
      (h) => h.name,
      UiPrefs.maxAutoHosts,
    );
    return hosts == null ? null : p.copyWith(autoHostAcp: hosts);
  });

  /// Remember the native OpenCode host the user just started on OpenCode's
  /// default database; it replaces any earlier record (one host serves that
  /// database at a time).
  void setAutoHostOpenCode(AutoHostOpenCodePrefs host) => _mutate((p) {
    final saved = p.autoHostOpenCode;
    if (saved?.name == host.name && saved?.binary == host.binary) return null;
    return p.copyWith(autoHostOpenCode: host);
  });

  /// Forget the OpenCode auto-host record when it names [name].
  void clearAutoHostOpenCode(String name) => _mutate(
    (p) => p.autoHostOpenCode?.name == name
        ? p.copyWith(clearAutoHostOpenCode: true)
        : null,
  );

  /// Forget the ACP auto-host record of [name] (stopped on purpose).
  void clearAutoHostAcp(String name) => _mutate((p) {
    final hosts = _without(p.autoHostAcp, name, (h) => h.name);
    return hosts == null ? null : p.copyWith(autoHostAcp: hosts);
  });
}

/// The durable UI prefs. `loading` until the file is read; consumers treat a
/// missing value as defaults. Decisions that must see the file (bounded
/// restore records) use [UiPrefsStore.ready] or the verdicts it reports.
final uiPrefsProvider = AsyncNotifierProvider<UiPrefsStore, UiPrefs>(
  UiPrefsStore.new,
);
