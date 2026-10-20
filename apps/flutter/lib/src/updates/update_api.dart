/// The update engine's surface (`engine::updates` in the bridge): plain Dart
/// mirrors so the UI and its tests do not import generated bindings. The
/// bridge implements it ([BridgeApi] extends [UpdateApi]).
library;

/// Where the update stands; see `UpdateStateDto` in the bridge.
class UpdateState {
  /// Creates a state.
  const UpdateState({
    required this.current,
    required this.phase,
    required this.method,
    required this.page,
    this.latest,
    this.newer = false,
    this.size,
    this.received = 0,
    this.checkedAtMs,
    this.failure,
    this.failureDetail,
    this.path,
    this.announced,
  });

  /// Before the engine answered.
  static const UpdateState unknown = UpdateState(
    current: '',
    phase: 'idle',
    method: 'release_page',
    page: 'https://github.com/acking-you/POCOX/releases/latest',
  );

  /// The running version.
  final String current;

  /// `idle`, `checking`, `up_to_date`, `available`, `downloading`,
  /// `verifying`, `ready`, `verified_only`, `installing`, `opened`, `saved`
  /// or `failed`.
  final String phase;

  /// The newest release, once a check found one.
  final String? latest;

  /// Whether [latest] is newer than the running version.
  final bool newer;

  /// How it applies here: `replace_bundle`, `installer`,
  /// `replace_app_image`, `open_package`, `save_download`,
  /// `system_installer` or `release_page`.
  final String method;

  /// The size of its file for this installation.
  final int? size;

  /// Bytes downloaded so far.
  final int received;

  /// The newest release's page.
  final String page;

  /// When GitHub last answered a check (Unix milliseconds).
  final int? checkedAtMs;

  /// Why the last action or background check failed.
  final String? failure;

  /// The underlying error of [failure].
  final String? failureDetail;

  /// The saved or opened file; on Android the package to install.
  final String? path;

  /// The newest version the user has been told about.
  final String? announced;

  /// Applying the update ends with the app quitting and reopening.
  bool get restarts => const {
    'replace_bundle',
    'installer',
    'replace_app_image',
  }.contains(method);

  /// Something runs (a check the user asked for, a download, a handover).
  bool get busy => const {
    'checking',
    'downloading',
    'verifying',
    'installing',
  }.contains(phase);
}

/// The update calls the UI makes.
abstract interface class UpdateApi {
  /// The state now.
  UpdateState updateState();

  /// The state now, then every change.
  Stream<UpdateState> updateWatch();

  /// Starts the quiet background check (once per process).
  void updateStartBackground();

  /// Checks now ([force]) or only when the last answer is old.
  Future<UpdateState> updateCheck({required bool force});

  /// Downloads and verifies the newest release's file.
  Future<UpdateState> updateDownload();

  /// Stops a download.
  void updateCancel();

  /// Applies the downloaded update.
  Future<UpdateState> updateInstall();

  /// Reports a failure of the app's own part (`quit`, `permission`,
  /// `install`).
  void updateReport(String kind, String detail);

  /// Remembers that the user was told about [version].
  void updateAnnounce(String version);
}
