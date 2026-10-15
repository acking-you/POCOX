// Native OpenCode reads its models, agents, variants and commands per
// project: a draft shows and applies the options of its own project, the
// command list follows the project the view shows, and a list answered for
// a project the view has left is never shown or used for another. The
// session's options replace the composer's Codex model menu. Switching
// projects sends nothing. Also: an OpenCode host never waits on Codex's own
// sign-in.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/opencode_chat.dart';

const _svc = openCodeService;
const _alpha = '/work/alpha';
const _beta = '/work/beta';

SessionSettings _models(List<(String, String)> models) => SessionSettings(
  configOptions: [
    SessionConfigOption(
      id: 'model',
      name: 'Model',
      category: 'model',
      currentValue: models.first.$1,
      values: [
        for (final (value, name) in models)
          SessionConfigValue(value: value, name: name),
      ],
    ),
  ],
);

const _mAlpha = ModelInfo(
  id: 'alpha/only',
  displayName: 'Alpha Only',
  description: '',
);

/// A desktop-sized new conversation in [_alpha]; the host knows both
/// projects from earlier sessions.
Future<(FakeBridgeApi, ProviderContainer)> _open(
  WidgetTester t, {
  bool localSessions = false,
  void Function(FakeBridgeApi, ProviderContainer)? seed,
}) async {
  t.view.physicalSize = const Size(1400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final api = FakeBridgeApi();
  // The capabilities the bridge reports: a model catalog together with
  // session and draft options.
  api.acpCapabilities[_svc] = negotiatedOpenCodeCapabilities(
    localSessions: localSessions,
  );
  api.appThreads.addAll(const [
    ThreadMeta(id: 'a0', preview: 'a', cwd: _alpha, updatedAt: 2),
    ThreadMeta(id: 'b0', preview: 'b', cwd: _beta, updatedAt: 1),
  ]);
  final container = ProviderContainer(
    overrides: [bridgeApiProvider.overrideWithValue(api)],
  );
  addTearDown(container.dispose);
  seed?.call(api, container);
  await api.appConnect(_svc, 28080);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppSessionScreen(serviceKey: _svc, cwd: _alpha),
      ),
    ),
  );
  await frames(t);
  return (api, container);
}

Future<void> _openOption(WidgetTester t) async {
  await t.tap(find.byKey(const Key('agent-config-model')));
  await t.pumpAndSettle();
}

Future<void> _closeOption(WidgetTester t) async {
  await t.tapAt(Offset.zero);
  await t.pumpAndSettle();
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('a draft shows and applies the options of its own project', (
    t,
  ) async {
    final (api, _) = await _open(
      t,
      seed: (api, _) => api.draftSettings
        ..['$_svc|$_alpha'] = _models([
          ('alpha/one', 'Alpha One'),
          ('alpha/two', 'Alpha Two'),
        ])
        ..['$_svc|$_beta'] = _models([('beta/one', 'Beta One')]),
    );
    expect(api.draftSettingsProjects, contains(_alpha));
    expect(optionShows('model', 'Alpha One'), findsOneWidget);
    await _openOption(t);
    await t.tap(optionChoice('alpha/two'));
    await t.pumpAndSettle();
    expect(optionShows('model', 'Alpha Two'), findsOneWidget);

    // Project B offers its own catalog, without A's choice or models.
    await pickProject(t, _beta);
    expect(api.draftSettingsProjects, contains(_beta));
    expect(optionShows('model', 'Beta One'), findsOneWidget);
    await _openOption(t);
    expect(optionChoice('alpha/two'), findsNothing);
    expect(optionChoice('alpha/one'), findsNothing);
    await _closeOption(t);

    // Back in A its draft still holds its choice; nothing went out.
    await pickProject(t, _alpha);
    expect(optionShows('model', 'Alpha Two'), findsOneWidget);
    expect(api.threadStartCalls, isEmpty);
    expect(api.sessionConfigCalls, isEmpty);
    expect(api.turnStartCount, 0);

    await typeMessage(t, 'hello');
    await tapSend(t);
    final thread = api.threadStartResults.single!;
    expect(api.lastCwd, _alpha);
    expect(api.sessionConfigCalls, [(thread, 'model', 'alpha/two')]);
    expect(api.lastTurnText, 'hello');
  });

  testWidgets('a draft of project B applies nothing chosen in project A', (
    t,
  ) async {
    final (api, _) = await _open(
      t,
      seed: (api, _) => api.draftSettings
        ..['$_svc|$_alpha'] = _models([
          ('shared/one', 'Shared One'),
          ('shared/two', 'Shared Two'),
        ])
        ..['$_svc|$_beta'] = _models([
          ('shared/one', 'Shared One'),
          ('shared/two', 'Shared Two'),
        ]),
    );
    await _openOption(t);
    await t.tap(optionChoice('shared/two'));
    await t.pumpAndSettle();
    await pickProject(t, _beta);
    // The same model id in B is not chosen there.
    expect(optionShows('model', 'Shared One'), findsOneWidget);
    await typeMessage(t, 'in beta');
    await tapSend(t);
    expect(api.lastCwd, _beta);
    expect(api.sessionConfigCalls, isEmpty);
    expect(api.lastTurnText, 'in beta');
  });

  testWidgets('the command list follows the project; a late answer for the '
      'project left is not shown', (t) async {
    final held = Completer<void>();
    addTearDown(() {
      if (!held.isCompleted) held.complete();
    });
    final (api, _) = await _open(
      t,
      seed: (api, _) {
        api.projectCommands
          ..['$_svc|$_alpha'] = const [
            AgentCommand(name: 'alpha-cmd', description: 'Alpha'),
          ]
          ..['$_svc|$_beta'] = const [
            AgentCommand(name: 'beta-cmd', description: 'Beta'),
          ];
        api.projectCommandGates[_alpha] = held;
      },
    );
    await typeMessage(t, '/');
    await frames(t);
    expect(api.commandListProjects, contains(_alpha));
    expect(find.byKey(const Key('command-palette')), findsNothing);

    await pickProject(t, _beta);
    await typeMessage(t, '/');
    await frames(t);
    expect(api.commandListProjects, contains(_beta));
    expect(find.byKey(const Key('command-beta-cmd')), findsOneWidget);

    // A's answer arrives after the view moved to B.
    held.complete();
    await frames(t);
    expect(find.byKey(const Key('command-beta-cmd')), findsOneWidget);
    expect(find.byKey(const Key('command-alpha-cmd')), findsNothing);
    expect(api.turnStartCount, 0);
    expect(api.threadStartCalls, isEmpty);
  });

  testWidgets('the session options replace the composer model menu; an '
      'inherited model default is never sent', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final (api, _) = await _open(
        t,
        seed: (api, container) {
          api.draftSettings
            ..['$_svc|$_alpha'] = _models([('alpha/one', 'Alpha One')])
            ..['$_svc|$_beta'] = _models([('beta/one', 'Beta One')]);
          // A model remembered on this service (the Codex menu's default).
          container.read(sessionDefaultsProvider(_svc).notifier).state =
              const SessionDefaults(model: _mAlpha);
        },
      );
      expect(find.byKey(const Key('model-chip')), findsNothing);
      expect(optionShows('model', 'Alpha One'), findsOneWidget);
      await pickProject(t, _beta);
      expect(find.byKey(const Key('model-chip')), findsNothing);
      expect(optionShows('model', 'Beta One'), findsOneWidget);
      expect(api.turnStartCount, 0, reason: 'switching sends nothing');
      await typeMessage(t, 'beta turn');
      await tapSend(t);
      expect(api.lastCwd, _beta);
      expectNoModelMenuSettings(api);
      expect(api.lastTurnText, 'beta turn');
      // No catalog is read for a menu that is not shown.
      expect(api.modelListProjects, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a local OpenCode host on its own sign-ins sends while Codex '
      'itself is not set up', (t) async {
    final (api, _) = await _open(
      t,
      // The real bridge reports this device's native history too.
      localSessions: true,
      seed: (api, _) =>
          api.serveHosts.add(FakeBridgeApi.openCodeHost('opencode')),
    );
    expect(api.codexStatus.needsSetup, isTrue, reason: 'Codex itself');
    expect(find.byKey(const Key('codex-chat-needs-setup')), findsNothing);
    await typeMessage(t, 'no codex needed');
    await tapSend(t);
    expect(api.threadStartCalls, [_svc]);
    expect(api.lastTurnText, 'no codex needed');
  });
}
