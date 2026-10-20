/// The update flow's state and actions. The engine (Rust) checks, downloads,
/// verifies and stages; the app's part is quitting through its normal path
/// so a helper can swap the new version in, handing an Android package to
/// the system installer, and opening the release page.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/src/desktop_tray.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/updates/update_api.dart';
import 'package:url_launcher/url_launcher.dart';

/// The update engine, part of the bridge.
final updateApiProvider = Provider<UpdateApi>(
  (ref) => ref.watch(bridgeApiProvider),
);

/// The update state, followed live.
final updateStateProvider = StreamProvider<UpdateState>(
  (ref) => ref.watch(updateApiProvider).updateWatch(),
);

/// The update flow's actions.
final updateActionsProvider = Provider<UpdateActions>(
  (ref) => UpdateActions(ref.watch(updateApiProvider)),
);

/// Android: the system installer, which asks the user and refuses a package
/// signed with a different certificate (`UpdateInstaller.kt`).
abstract final class AndroidUpdateInstaller {
  static const MethodChannel _channel = MethodChannel('pocket_codex/updates');

  /// Whether the user has let POCOX install packages.
  static Future<bool> canInstall() async =>
      await _channel.invokeMethod<bool>('canInstall') ?? false;

  /// Opens the setting that lets POCOX install packages.
  static Future<void> openInstallSettings() =>
      _channel.invokeMethod<void>('openInstallSettings');

  /// Hands the package at [path] to the system installer.
  static Future<void> install(String path) =>
      _channel.invokeMethod<void>('install', {'path': path});
}

/// What the update buttons do.
class UpdateActions {
  /// Actions over [api]; the app's own parts are injectable for tests.
  UpdateActions(
    this.api, {
    Future<String?> Function()? quit,
    Future<void> Function(String path)? systemInstall,
    Future<void> Function(String url)? open,
  }) : _quit = quit ?? _quitApp,
       _systemInstall = systemInstall ?? _installAndroid,
       _open = open ?? _openExternal;

  /// The engine.
  final UpdateApi api;
  final Future<String?> Function() _quit;
  final Future<void> Function(String path) _systemInstall;
  final Future<void> Function(String url) _open;

  /// Quits through the tray's path (hosted services stop first); returns
  /// why it could not, if it returns at all.
  static Future<String?> _quitApp() async {
    await DesktopTray.instance.quit();
    return DesktopTray.instance.quitStatus.value?.error;
  }

  static Future<void> _installAndroid(String path) async {
    if (!await AndroidUpdateInstaller.canInstall()) {
      await AndroidUpdateInstaller.openInstallSettings();
      throw const _NeedsPermission();
    }
    await AndroidUpdateInstaller.install(path);
  }

  static Future<void> _openExternal(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  /// Checks GitHub now.
  Future<void> checkNow() => api.updateCheck(force: true);

  /// Stops a download.
  void cancel() => api.updateCancel();

  /// Opens the newest release's page.
  Future<void> openPage() => _open(api.updateState().page);

  /// The one-click update: fetch, verify and apply the newest release the
  /// way this installation allows. A failure lands in the state, which the
  /// UI shows; nothing here throws.
  Future<void> updateNow() async {
    var state = api.updateState();
    if (state.method == 'release_page') {
      await openPage();
      return;
    }
    state = await api.updateDownload();
    if (state.phase != 'ready') return;
    state = await api.updateInstall();
    if (state.phase == 'installing' && state.restarts) {
      // The helper is waiting for this process to exit.
      final blocked = await _quit();
      if (blocked != null) api.updateReport('quit', blocked);
    } else if (state.phase == 'opened' && state.method == 'system_installer') {
      try {
        await _systemInstall(state.path!);
      } on _NeedsPermission {
        api.updateReport('permission', 'install permission not granted');
      } catch (error) {
        api.updateReport('install', '$error');
      }
    }
  }
}

class _NeedsPermission implements Exception {
  const _NeedsPermission();
}
