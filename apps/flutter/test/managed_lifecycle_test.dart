// Late answers and moved destinations in remote management: an operation
// that completes after its page was left, or after the panel moved to
// another computer, is neither repeated nor shown on the wrong computer, and
// raises nothing. The default-project tile resets per host, locks after a
// conflict until an explicit reload, and keeps its advanced roots. A saved
// non-Claude ACP agent keeps its own (conservative) model-service support.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/managed/default_project_tile.dart';
import 'package:pocox/src/managed/device_management_switch.dart';
import 'package:pocox/src/managed/managed_device_panel.dart';
import 'package:pocox/src/managed/managed_host_editor.dart';
import 'package:pocox/src/providers.dart';

import 'fake_bridge_api.dart';

const _a = 'pcx:studio:host:studio';
const _b = 'pcx:lab:host:lab';
final _en = lookupAppLocalizations(const Locale('en'));

ManagedHost _running(String name, String device) => ManagedHost(
  name: name,
  status: AppServeStatus(
    name: name,
    device: device,
    alive: true,
    appServiceKey: 'pcx:$device:app:$name',
    incarnation: 'inc-$name',
  ),
  config: HostConfig(
    revision: 3,
    runtime: const HostRuntime.codex(port: 18100),
    active: HostActive(
      incarnation: 'inc-$name',
      runtime: const HostRuntime.codex(port: 18100),
      revision: 3,
    ),
  ),
);

FakeBridgeApi _fake() {
  final api = FakeBridgeApi();
  api.managedDevices[_a] = ManagedDevice(
    device: 'studio',
    os: 'macOS',
    appVersion: '0.9.0',
    hosts: [_running('work', 'studio')],
  );
  api.managedDevices[_b] = ManagedDevice(
    device: 'lab',
    os: 'linux',
    appVersion: '0.9.0',
    hosts: [_running('work', 'lab')],
  );
  return api;
}

Widget _app(Widget child, BridgeApi api) => ProviderScope(
  overrides: [bridgeApiProvider.overrideWithValue(api)],
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

/// [builder] under a switchable value: flipping it moves the same State to
/// another destination (or removes it).
Widget _switchable<T>(ValueNotifier<T> value, Widget Function(T) builder) =>
    ValueListenableBuilder<T>(
      valueListenable: value,
      builder: (_, v, _) => builder(v),
    );

Future<void> _tap(WidgetTester t, Finder finder) async {
  await t.ensureVisible(finder);
  await t.pumpAndSettle();
  await t.tap(finder);
  await t.pumpAndSettle();
}

void main() {
  group('device panel', () {
    Future<ValueNotifier<String?>> pumpPanel(
      WidgetTester t,
      FakeBridgeApi api,
    ) async {
      final key = ValueNotifier<String?>(_a);
      await t.pumpWidget(
        _app(
          _switchable<String?>(
            key,
            (k) => k == null
                ? const SizedBox()
                : ManagedDevicePanel(serviceKey: k, device: 'studio'),
          ),
          api,
        ),
      );
      await t.pumpAndSettle();
      return key;
    }

    testWidgets('a stop confirmed after the panel moved to another computer '
        'is not sent', (t) async {
      final api = _fake();
      final key = await pumpPanel(t, api);
      await _tap(t, find.byKey(const Key('managed-stop-work')));
      // The panel now shows another computer behind the open dialog.
      key.value = _b;
      await t.pump();
      await t.tap(find.byKey(const Key('managed-confirm-ok')));
      await t.pumpAndSettle();
      expect(api.managedCalls, isEmpty);
      expect(t.takeException(), isNull);
    });

    testWidgets('a start answered after the panel moved is not shown on the '
        'other computer', (t) async {
      final api = _fake();
      api.managedDevices[_a] = ManagedDevice(
        device: 'studio',
        os: 'macOS',
        appVersion: '0.9.0',
        hosts: [
          ManagedHost(
            name: 'work',
            config: HostConfig(
              revision: 2,
              runtime: const HostRuntime.opencode(),
            ),
          ),
        ],
      );
      api.managedGate = Completer<void>();
      final key = await pumpPanel(t, api);
      await t.tap(find.byKey(const Key('managed-start-work')));
      await t.pump();
      key.value = _b;
      await t.pumpAndSettle();
      api.managedGate!.complete();
      await t.pumpAndSettle();
      expect(api.managedCalls.single.key, _a);
      expect(find.byKey(const Key('managed-result-work')), findsNothing);
      expect(find.byKey(const Key('managed-row-pending')), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  testWidgets('an editor save answered after the editor was removed raises '
      'nothing', (t) async {
    final api = _fake()..managedGate = Completer<void>();
    final shown = ValueNotifier(true);
    await t.pumpWidget(
      ProviderScope(
        overrides: [bridgeApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: _switchable<bool>(
            shown,
            (v) => v
                ? ManagedHostEditor(
                    serviceKey: _a,
                    device: 'studio',
                    host: api.managedDevices[_a]!.hosts.single,
                  )
                : const SizedBox(),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('managed-port')), '18200');
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const Key('managed-save')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('managed-save')));
    await t.pump();
    shown.value = false;
    await t.pump();
    api.managedGate!.complete();
    await t.pumpAndSettle();
    expect(api.managedCalls, hasLength(1));
    expect(t.takeException(), isNull);
  });

  testWidgets('the management switch answered after it was removed raises '
      'nothing', (t) async {
    final api = FakeBridgeApi()..deviceManagementGate = Completer<void>();
    final shown = ValueNotifier(true);
    await t.pumpWidget(
      _app(
        _switchable<bool>(
          shown,
          (v) => v ? const DeviceManagementSwitch() : const SizedBox(),
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('device-management-switch')));
    await t.pump();
    shown.value = false;
    await t.pump();
    api.deviceManagementGate!.complete();
    await t.pumpAndSettle();
    expect(api.deviceManagementSets, [true]);
    expect(t.takeException(), isNull);
  });

  group('default project tile', () {
    const explicit = ProjectSettings(
      revision: '8',
      projectRoots: ['/srv'],
      defaultProject: '/srv/app',
      effectiveDefault: '/srv/app',
      exists: true,
    );
    const other = ProjectSettings(
      revision: '1',
      defaultProject: '/lab/main',
      effectiveDefault: '/lab/main',
      exists: true,
    );

    Future<ValueNotifier<String>> pumpTile(
      WidgetTester t,
      FakeBridgeApi api,
    ) async {
      final key = ValueNotifier(_a);
      await t.pumpWidget(
        _app(
          _switchable<String>(key, (k) => DefaultProjectTile(serviceKey: k)),
          api,
        ),
      );
      await t.pumpAndSettle();
      return key;
    }

    bool enabled(WidgetTester t, String key) =>
        t.widget<ButtonStyleButton>(find.byKey(Key(key))).onPressed != null;

    testWidgets('a host switch during a save leaves the new host usable and '
        'drops the old answer', (t) async {
      final api = FakeBridgeApi()
        ..projectSettings[_a] = explicit
        ..projectSettings[_b] = other
        ..projectSaveGate = Completer<void>();
      final key = await pumpTile(t, api);
      await t.tap(find.byKey(const Key('default-project-automatic')));
      await t.pump();
      key.value = _b;
      await t.pumpAndSettle();
      expect(find.text('/lab/main'), findsOneWidget);
      expect(enabled(t, 'default-project-change'), isTrue);
      api.projectSaveGate!.complete();
      await t.pumpAndSettle();
      expect(find.text('/lab/main'), findsOneWidget);
      expect(find.byKey(const Key('default-project-error')), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('after a conflict nothing saves until an explicit reload', (
      t,
    ) async {
      final api = FakeBridgeApi()..projectSettings[_a] = explicit;
      await pumpTile(t, api);
      api.projectSettings[_a] = const ProjectSettings(
        revision: '9',
        defaultProject: '/srv/other',
        effectiveDefault: '/srv/other',
        exists: true,
      );
      await t.tap(find.byKey(const Key('default-project-automatic')));
      await t.pumpAndSettle();
      expect(find.text(_en.defaultProjectConflict), findsOneWidget);
      expect(enabled(t, 'default-project-change'), isFalse);
      expect(enabled(t, 'default-project-automatic'), isFalse);
      await _tap(t, find.byKey(const Key('default-project-reload')));
      expect(find.text('/srv/other'), findsOneWidget);
      expect(enabled(t, 'default-project-automatic'), isTrue);
      await _tap(t, find.byKey(const Key('default-project-automatic')));
      expect(api.projectSettingsSaves.map((s) => s.rev), ['8', '9']);
    });

    testWidgets('a root is added and removed with the current revision; the '
        'default stays its own setting', (t) async {
      final api = FakeBridgeApi()..projectSettings[_a] = explicit;
      await pumpTile(t, api);
      await _tap(t, find.byKey(const Key('default-project-advanced')));
      await _tap(t, find.byKey(const Key('add-project-folder-btn')));
      await t.enterText(find.byKey(const Key('project-root-path')), '/data');
      await _tap(t, find.byKey(const Key('project-root-add')));
      final add = api.projectSettingsSaves.single;
      expect(add.roots, ['/srv', '/data']);
      expect((add.def, add.rev), ('/srv/app', '8'));
      expect(find.byKey(const Key('project-root-/data')), findsOneWidget);
      await _tap(t, find.byKey(const Key('remove-project-/srv')));
      final remove = api.projectSettingsSaves.last;
      expect(remove.roots, ['/data']);
      expect((remove.def, remove.rev), ('/srv/app', '9'));
    });

    testWidgets('a refused root save keeps what is shown', (t) async {
      final api = FakeBridgeApi()
        ..projectSettings[_a] = explicit
        ..projectSaveError = Exception(
          'outside_project_roots (400): The folder is not allowed.',
        );
      await pumpTile(t, api);
      await _tap(t, find.byKey(const Key('default-project-advanced')));
      await _tap(t, find.byKey(const Key('remove-project-/srv')));
      expect(find.byKey(const Key('project-root-/srv')), findsOneWidget);
      expect(find.text('/srv/app'), findsOneWidget);
      expect(find.byKey(const Key('default-project-error')), findsOneWidget);
      expect(enabled(t, 'default-project-change'), isTrue);
    });
  });

  testWidgets('a saved non-Claude ACP agent keeps its own name and support, '
      'and its runtime is never sent', (t) async {
    const agent = AcpAgentSpec(
      profileId: 'custom-x',
      displayName: 'My Agent',
      program: 'agent',
    );
    final host = ManagedHost(
      name: 'mine',
      config: HostConfig(revision: 4, runtime: const HostRuntime.acp(agent)),
    );
    final api = FakeBridgeApi()
      ..managedDevices[_a] = ManagedDevice(
        device: 'studio',
        os: 'macOS',
        appVersion: '0.9.0',
        hosts: [host],
      );
    await t.pumpWidget(
      ProviderScope(
        overrides: [bridgeApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ManagedHostEditor(serviceKey: _a, device: 'studio', host: host),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('My Agent'), findsOneWidget);
    expect(find.text('Claude'), findsNothing);
    expect(find.byKey(const Key('claude-environment-section')), findsNothing);
    // Its own configuration is the only model service: no choice is shown,
    // only what it uses.
    expect(find.byKey(const Key('host-source-inherited')), findsNothing);
    expect(find.byKey(const Key('host-source-custom')), findsNothing);
    expect(find.text(_en.managedInheritedNote), findsOneWidget);
    expect(find.byKey(const Key('managed-port')), findsNothing);
    expect(
      managedModelSummary(_en, host),
      startsWith('My Agent'),
      reason: 'the panel row names the agent too',
    );
  });
}
