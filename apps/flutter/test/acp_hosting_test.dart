// ACP hosting: the agent grid, a generic preset and custom agents,
// verbatim argument vectors, saved agents, host details, restore planning,
// preference compatibility, and phone/tablet/desktop layouts in both themes.

import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart'
    as fsel;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/acp_host_form.dart';
import 'package:pocket_codex/src/hosting/host_names.dart';
import 'package:pocket_codex/src/hosting/host_restore.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/service_key.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/widgets/agent_icon.dart';
import 'package:pocket_codex/src/widgets/local_host_dialog.dart';

import 'fake_bridge_api.dart';
import 'package:pocket_codex/src/app_icons.dart';

part 'acp_hosting/claude_preparation.dart';
part 'acp_hosting/lifecycle.dart';
part 'acp_hosting/presets.dart';
part 'acp_hosting/restore.dart';
part 'acp_hosting/selection_ownership.dart';

/// A file picker whose single-file pick waits for [gate].
class _GatedPicker extends fsel.FileSelectorPlatform
    with MockPlatformInterfaceMixin {
  _GatedPicker(this.path);

  final String path;
  final Completer<void> gate = Completer<void>();
  bool opened = false;

  @override
  Future<fsel.XFile?> openFile({
    List<fsel.XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    opened = true;
    await gate.future;
    return fsel.XFile(path);
  }
}

/// A preference store over [saved] in memory, whose initial load waits for
/// [gate] when given. Records what it writes.
class _HeldPrefs extends UiPrefsStore {
  _HeldPrefs(this.saved, [this.gate]);

  final UiPrefs saved;
  final Completer<void>? gate;
  final List<UiPrefs> written = [];

  @override
  Future<UiPrefs> load() async {
    await gate?.future;
    return saved;
  }

  @override
  Future<void> save(UiPrefs prefs) async => written.add(prefs);
}

Future<ProviderContainer> _pumpDialog(
  WidgetTester t,
  FakeBridgeApi api, {
  AppServeStatus? existing,
  Size size = const Size(1280, 900),
  Brightness brightness = Brightness.light,
  _HeldPrefs? prefs,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final container = ProviderContainer(
    overrides: [
      bridgeApiProvider.overrideWithValue(api),
      if (prefs != null) uiPrefsProvider.overrideWith(() => prefs),
    ],
  );
  addTearDown(container.dispose);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        theme: ThemeData(brightness: brightness),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            // The editor is a page, pushed as the app pushes it.
            body: TextButton(
              onPressed: () => showHostingEditor(context, existing: existing),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  return container;
}

/// Unfold the "Advanced" disclosure [key]. The toggle spans the form's
/// width with its button at the start, so the button itself is revealed and
/// tapped (the toggle's centre is empty space), and the unfolded state is
/// asserted.
Future<void> _openAdvanced(WidgetTester t, String key) async {
  final button = find.descendant(
    of: find.byKey(Key(key)),
    matching: find.byType(TextButton),
  );
  expect(button, findsOneWidget);
  await t.ensureVisible(button);
  await t.pumpAndSettle();
  await t.tap(button);
  await t.pumpAndSettle();
  expect(
    find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byIcon(AppIcons.expand_less_rounded),
    ),
    findsOneWidget,
    reason: 'the advanced fields are unfolded',
  );
}

/// Pick the preset tile [id] (the fixture preset by default) and unfold its
/// program and arguments.
Future<void> _chooseAcp(WidgetTester t, [String id = 'fixture']) async {
  final tile = find.byKey(Key('agent-choice-preset:$id'));
  await t.ensureVisible(tile);
  await t.tap(tile);
  await t.pumpAndSettle();
  // Let the debounced program lookup settle.
  await t.pump(const Duration(milliseconds: 400));
  await t.pumpAndSettle();
  // A platform without ACP hosting shows no form, hence no toggle.
  if (find.byKey(const Key('acp-advanced-toggle')).evaluate().isNotEmpty) {
    await _openAdvanced(t, 'acp-advanced-toggle');
  }
}

/// Pick the "custom agent" tile (its program fields start unfolded).
Future<void> _chooseCustom(WidgetTester t) async {
  final tile = find.byKey(const Key('agent-choice-custom'));
  await t.ensureVisible(tile);
  await t.tap(tile);
  await t.pumpAndSettle();
}

/// Pick the Codex tile.
Future<void> _chooseCodex(WidgetTester t) async {
  final tile = find.byKey(const Key('agent-choice-codex'));
  await t.ensureVisible(tile);
  await t.tap(tile);
  await t.pumpAndSettle();
}

Future<void> _start(WidgetTester t) async {
  await t.ensureVisible(find.byKey(const Key('start-hosting-btn')));
  await t.tap(find.byKey(const Key('start-hosting-btn')));
  await t.pumpAndSettle();
}

const _acpHost = AppServeStatus(
  name: 'beta',
  device: 'local',
  alive: true,
  appListenAddr: '127.0.0.1:18200',
  appServiceKey: 'pcx:local:acp:beta',
  appRegistered: true,
  metaListenAddr: '127.0.0.1:18201',
  metaServiceKey: 'pcx:local:meta:beta',
  metaRegistered: true,
  codexBinary: '/opt/agents/beta agent',
  provider: 'acp',
  protocol: 'acp',
  providerName: 'Beta agent',
  profileId: 'custom-beta',
  agentPhase: 'failed',
  agentError: 'the agent exited',
  authRequired: true,
);

void main() {
  _registerPresets();
  _registerClaudePreparation();
  _registerRestore();
  _registerSelectionOwnership();
  _registerLifecycle();
}
