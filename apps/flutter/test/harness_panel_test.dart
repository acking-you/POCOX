// Each computer's agents: their versions and newer releases, an update run
// on that computer with its own installer and its services restarted after
// it, and settings kept per computer. Lost or refused answers are explained,
// never resent.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/harnesses/harness_panel.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/theme.dart';

import 'fake_bridge_api.dart';

const _studio = 'pcx:studio:host:studio';
final _en = lookupAppLocalizations(const Locale('en'));

HarnessInfo _codex({
  String version = '0.46.0',
  String latest = '0.47.0',
  bool canUpdate = true,
  String? problem,
  List<String> services = const ['default'],
}) => HarnessInfo(
  kind: 'codex',
  installed: true,
  version: version,
  latest: latest,
  updateAvailable: version != latest,
  method: canUpdate ? 'npm' : null,
  canUpdate: canUpdate,
  problem: problem,
  services: services,
);

HarnessOverview _overview(List<HarnessInfo> harnesses) => HarnessOverview(
  harnesses: harnesses,
  checkedAtMs: DateTime.now().millisecondsSinceEpoch,
);

Widget _app(Widget child, BridgeApi api) => ProviderScope(
  overrides: [bridgeApiProvider.overrideWithValue(api)],
  child: MaterialApp(
    locale: const Locale('en'),
    theme: lightTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

Finder _within(String key, Finder finder) =>
    find.descendant(of: find.byKey(Key(key)), matching: finder);

void main() {
  testWidgets('an update runs on that computer and restarts its services', (
    t,
  ) async {
    final api = FakeBridgeApi();
    api.harnessOverviews[_studio] = _overview([_codex()]);
    await t.pumpWidget(_app(const HarnessPanel(serviceKey: _studio), api));
    await t.pumpAndSettle();

    expect(find.text('0.46.0 · npm'), findsOneWidget);
    expect(find.text(_en.harnessUsedBy('default')), findsOneWidget);
    await t.tap(find.byKey(const Key('harness-update-codex')));
    await t.pumpAndSettle();
    // What happens to the services is said before anything is sent.
    expect(find.text(_en.harnessConfirmRestart('default')), findsOneWidget);
    expect(api.harnessCalls, isEmpty);
    await t.tap(find.byKey(const Key('managed-confirm-ok')));
    await t.pump();
    await t.pump();

    expect(api.harnessCalls.single, (op: 'update', key: _studio, arg: 'codex'));
    expect(find.byKey(const Key('harness-updating-codex')), findsOneWidget);
    expect(find.text(_en.harnessStageUpdating), findsOneWidget);
    expect(find.byKey(const Key('harness-update-codex')), findsNothing);

    api.finishHarnessUpdate(
      _studio,
      toVersion: '0.47.0',
      restarted: const ['default'],
    );
    await t.pump(const Duration(seconds: 1));
    await t.pumpAndSettle();
    expect(
      find.text(
        '${_en.harnessUpdated('0.47.0')} ${_en.harnessRestarted('default')}',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('harness-current-codex')), findsOneWidget);
    expect(api.harnessCalls, hasLength(1), reason: 'nothing is sent again');
  });

  testWidgets('each computer keeps its own settings', (t) async {
    final api = FakeBridgeApi();
    api.harnessOverviews[''] = _overview([_codex(services: const [])]);
    api.harnessOverviews[_studio] = _overview([_codex()]);
    await t.pumpWidget(
      _app(
        const Column(
          children: [
            HarnessPanel(),
            HarnessPanel(serviceKey: _studio),
          ],
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    await t.tap(
      _within(
        'harnesses-$_studio',
        find.byKey(const Key('harness-auto-codex')),
      ),
    );
    await t.pumpAndSettle();
    expect(api.harnessCalls.single, (
      op: 'settings',
      key: _studio,
      arg: (kind: 'codex', autoUpdate: true, restart: null),
    ));
    SwitchListTile auto(String panel) =>
        t.widget(_within(panel, find.byKey(const Key('harness-auto-codex'))));
    expect(auto('harnesses-$_studio').value, isTrue);
    expect(auto('harnesses-local').value, isFalse);

    await t.tap(
      _within('harnesses-local', find.byKey(const Key('harness-restart'))),
    );
    await t.pumpAndSettle();
    expect(api.harnessCalls.last, (
      op: 'settings',
      key: null,
      arg: (kind: null, autoUpdate: null, restart: false),
    ));
    expect(
      _within('harnesses-local', find.text(_en.harnessRestartOff)),
      findsOneWidget,
    );
    expect(
      _within('harnesses-$_studio', find.text(_en.harnessRestartOn)),
      findsOneWidget,
    );
  });

  testWidgets('what cannot be updated says why; refusals are explained', (
    t,
  ) async {
    final api = FakeBridgeApi();
    api.harnessOverviews[_studio] = _overview([
      _codex(canUpdate: false, problem: 'unmanaged'),
      const HarnessInfo(
        kind: 'grok',
        installed: true,
        version: '1.0.61',
        latest: '1.0.62',
        updateAvailable: true,
        method: 'own',
        canUpdate: true,
      ),
    ]);
    await t.pumpWidget(
      _app(
        const Column(
          children: [
            HarnessPanel(serviceKey: _studio),
            // An older POCOX without harness management.
            HarnessPanel(serviceKey: 'pcx:old:host:old'),
          ],
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    expect(find.byKey(const Key('harness-update-codex')), findsNothing);
    expect(find.text(_en.updateAvailable('0.47.0')), findsOneWidget);
    expect(find.text(_en.harnessProblemUnmanaged), findsOneWidget);
    expect(find.byKey(const Key('harnesses-pcx:old:host:old')), findsNothing);

    api.harnessUpdateError = Exception(
      'update_running (409): Another agent update is running on this computer.',
    );
    await t.tap(find.byKey(const Key('harness-update-grok')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('managed-confirm-ok')));
    await t.pumpAndSettle();
    expect(find.text(_en.harnessUpdateRunning), findsOneWidget);
    expect(api.harnessCalls.where((c) => c.op == 'update'), hasLength(1));
  });
}
