// The hosting editor: one page for new and running hosts. A new host is
// saved and started as one operation; a running host's runtime and model
// service are read first, saved without touching what runs, and applied
// only by an explicit, confirmed restart of exactly the revision shown.
// Only the agent/provider mappings the bridge supports are offered, leaving
// with unsaved edits asks first, and the official sign-in owns its private
// session. Pending UI is driven with completers and finite pumps.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/host_editor_page.dart';
import 'package:pocket_codex/src/hosting/model_service_section.dart';
import 'package:pocket_codex/src/hosting/official_login_panel.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/services_screen.dart';
import 'package:pocket_codex/src/widgets/utility_page.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

part 'hosting_editor/new_host.dart';
part 'hosting_editor/running_host.dart';
part 'hosting_editor/navigation.dart';
part 'hosting_editor/sign_in.dart';
part 'hosting_editor/opencode_host.dart';

const _codexHost = AppServeStatus(
  name: 'alpha',
  device: 'local',
  pid: 4242,
  alive: true,
  appListenAddr: '127.0.0.1:18080',
  appServiceKey: 'pcx:local:app:alpha',
  appRegistered: true,
  metaListenAddr: '127.0.0.1:18090',
  metaServiceKey: 'pcx:local:meta:alpha',
  metaRegistered: true,
  codexBinary: '/usr/local/bin/codex',
  proxy: 'http://127.0.0.1:11111',
  provider: 'codex',
  configSource: 'inherited',
  configRevision: 0,
  incarnation: 'inc-alpha',
);

/// A generic ACP agent with no preset and no restore record.
const _genericAgent = AcpAgentSpec(
  profileId: 'custom-tool-1a2b3c4d',
  displayName: 'Tool',
  program: '/opt/tool/bin/tool-acp',
  args: ['--stdio', '--quiet'],
);

const _acpHost = AppServeStatus(
  name: 'tool',
  device: 'local',
  alive: true,
  appListenAddr: '127.0.0.1:18200',
  appServiceKey: 'pcx:local:acp:tool',
  appRegistered: true,
  metaListenAddr: '127.0.0.1:18201',
  metaServiceKey: 'pcx:local:meta:tool',
  metaRegistered: true,
  codexBinary: '/opt/tool/bin/tool-acp',
  provider: 'acp',
  protocol: 'acp',
  providerName: 'Tool',
  profileId: 'custom-tool-1a2b3c4d',
  agentPhase: 'ready',
  configSource: 'inherited',
  configRevision: 0,
  incarnation: 'inc-tool',
);

/// A fake offering a generic ACP preset and the Claude adapter (as
/// `PRESETS` in host-svc's `acp/spec.rs` defines it), with the adapter found
/// where the fake's Claude status reports it. The default fake offers the
/// generic preset only.
FakeBridgeApi _withClaude() => FakeBridgeApi()
  ..presets = const [
    fixturePreset,
    AcpPreset(
      id: 'claude',
      displayName: 'Claude',
      program: 'claude-agent-acp',
      args: [],
    ),
  ]
  ..acpPrograms['claude-agent-acp'] =
      '/Users/me/.npm-global/bin/claude-agent-acp';

Future<ProviderContainer> _pumpEditor(
  WidgetTester t,
  FakeBridgeApi api, {
  AppServeStatus? existing,
}) async {
  t.view.physicalSize = const Size(1280, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final container = ProviderContainer(
    overrides: [bridgeApiProvider.overrideWithValue(api)],
  );
  addTearDown(container.dispose);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
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

AppLocalizations _l10n(WidgetTester t) =>
    AppLocalizations.of(t.element(find.byType(HostingEditor)));

AppLocalizations _l10nOf(WidgetTester t) =>
    AppLocalizations.of(t.element(find.byType(Scaffold).first));

Future<void> _tapKey(WidgetTester t, String key) async {
  final target = find.byKey(Key(key));
  await t.ensureVisible(target);
  await t.pumpAndSettle();
  await t.tap(target);
  await t.pumpAndSettle();
}

/// Tap without settling: for a sign-in whose spinner keeps animating.
Future<void> _tapKeyPumped(WidgetTester t, String key) async {
  final target = find.byKey(Key(key));
  await t.ensureVisible(target);
  await t.pump();
  await t.tap(target);
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// Open an Advanced disclosure through its button: the toggle spans the
/// form's width with the button at its start, so its centre is no target.
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
}

Future<void> _enter(WidgetTester t, String key, String text) async {
  final field = find.byKey(Key(key));
  await t.ensureVisible(field);
  await t.enterText(field, text);
  await t.pumpAndSettle();
}

Future<void> _choosePreset(WidgetTester t, String id) async {
  await _tapKey(t, 'agent-choice-preset:$id');
  // Let the debounced program lookup settle.
  await t.pump(const Duration(milliseconds: 400));
  await t.pumpAndSettle();
}

VoidCallback? _onPressed(WidgetTester t, String key) {
  final widget = t.widget(find.byKey(Key(key)));
  return switch (widget) {
    final ButtonStyleButton b => b.onPressed,
    _ => throw StateError('$key is not a button'),
  };
}

/// Answer url_launcher's platform channel so a sign-in can open its page.
void _mockLauncher(WidgetTester t) {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async => true,
  );
  addTearDown(
    () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
}

void main() {
  _newHostTests();
  _runningHostTests();
  _navigationTests();
  _entryTests();
  _signInTests();
  _openCodeHostTests();
}

extension on AppServeStatus {
  /// This host under another [name].
  AppServeStatus copyName(String name) => AppServeStatus(
    name: name,
    device: device,
    pid: pid,
    alive: alive,
    appListenAddr: appListenAddr,
    appServiceKey: 'pcx:local:app:$name',
    appRegistered: appRegistered,
    metaListenAddr: metaListenAddr,
    metaServiceKey: 'pcx:local:meta:$name',
    metaRegistered: metaRegistered,
    codexBinary: codexBinary,
    proxy: proxy,
    provider: provider,
    configSource: configSource,
    configRevision: configRevision,
    incarnation: 'inc-$name',
  );
}
