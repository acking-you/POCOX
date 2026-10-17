// The Add service sheet on a phone, opened through its real entrance (the
// management panel's Add service button and the adaptive bottom sheet): each
// runtime shows its name and a short availability line; long paths and
// explanations sit behind an explicit Details button. Every state stays
// reachable: choosing a ready runtime, blocked OpenCode, unavailable, sign-in
// on the host, Claude preparation, loading errors and retry. Real fonts.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/services_screen.dart';
import 'package:pocket_codex/src/theme.dart';

import 'fake_bridge_api.dart';
import 'support/ui_preview.dart';

const _mgmt = 'pcx:studio:host:studio';
final _en = lookupAppLocalizations(const Locale('en'));

const _codexPath = '/opt/homebrew/bin/codex';
const _openCodePath = '/Users/someone/.nvm/versions/node/v20.20.1/bin/opencode';
const _claudePath =
    '/Users/someone/Library/Application Support/io.github.acking-you.'
    'pocket-codex/acp-runtime/claude-agent-acp/node_modules/.bin/'
    'claude-agent-acp';

const _runtimes = [
  ManagedRuntimeAvailability(
    kind: 'codex',
    ready: true,
    path: _codexPath,
    version: '0.130.0',
    needsHostLogin: true,
  ),
  ManagedRuntimeAvailability(
    kind: 'opencode',
    ready: true,
    path: _openCodePath,
    version: '1.19.0',
  ),
  ManagedRuntimeAvailability(kind: 'claude', ready: true, path: _claudePath),
];

ManagedHost _openCodeRunning() => ManagedHost(
  name: 'opencode',
  status: const AppServeStatus(
    name: 'opencode',
    device: 'studio',
    alive: true,
    provider: 'opencode',
    appServiceKey: 'pcx:studio:opencode:opencode',
    incarnation: 'inc-oc',
  ),
  config: HostConfig(
    revision: 1,
    runtime: const HostRuntime.opencode(),
    active: const HostActive(
      incarnation: 'inc-oc',
      runtime: HostRuntime.opencode(),
      revision: 1,
    ),
  ),
);

FakeBridgeApi _fake({
  List<ManagedRuntimeAvailability> runtimes = _runtimes,
  List<ManagedHost>? hosts,
}) {
  final api = FakeBridgeApi(
    services: const [
      ServiceEntry(device: 'studio', kind: 'host', name: 'studio', key: _mgmt),
    ],
  );
  api.managedDevices[_mgmt] = ManagedDevice(
    device: 'studio',
    os: 'macOS',
    appVersion: '0.9.0',
    hosts: hosts ?? [_openCodeRunning()],
  );
  api.managedRuntimeLists[_mgmt] = runtimes;
  return api;
}

Widget _app(
  BridgeApi api, {
  double textScale = 1,
  Locale locale = const Locale('en'),
}) => ProviderScope(
  overrides: [bridgeApiProvider.overrideWithValue(api)],
  child: MaterialApp(
    locale: locale,
    theme: lightTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: const ServicesScreen(),
  ),
);

/// Open the sheet the way a person does: the computer, then Add service.
Future<void> _openSheet(
  WidgetTester t,
  FakeBridgeApi api, {
  Size size = const Size(393, 852),
  double textScale = 1,
  Locale locale = const Locale('en'),
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app(api, textScale: textScale, locale: locale));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('device-studio')));
  await t.pumpAndSettle();
  final add = find.byKey(const Key('managed-add-service'));
  await t.ensureVisible(add);
  await t.pumpAndSettle();
  await t.tap(add);
  await t.pumpAndSettle();
  expect(find.byKey(const Key('managed-add-panel')), findsOneWidget);
}

/// The availability line of the runtime row [kind].
String? _status(WidgetTester t, String kind) =>
    t.widget<Text>(find.byKey(Key('managed-runtime-status-$kind'))).data;

Future<void> _tap(WidgetTester t, Finder finder) async {
  await t.ensureVisible(finder);
  await t.pumpAndSettle();
  await t.tap(finder);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => loadPreviewFonts(always: true));

  testWidgets('rows show name and availability; paths only under Details', (
    t,
  ) async {
    await _openSheet(t, _fake());
    expect(find.text(_codexPath), findsNothing);
    expect(find.text(_openCodePath), findsNothing);
    expect(find.text(_claudePath), findsNothing);
    expect(_status(t, 'codex'), _en.managedRuntimeSignInThere);
    // OpenCode is offered beside the one already running there.
    expect(_status(t, 'opencode'), '${_en.managedRuntimeReady} · 1.19.0');
    expect(_status(t, 'claude'), _en.managedRuntimeReady);
    await _tap(t, find.byKey(const Key('managed-runtime-details-codex')));
    expect(find.text(_codexPath), findsOneWidget);
    expect(find.text('0.130.0'), findsOneWidget);
    expect(find.text(_en.managedNeedsHostLogin), findsOneWidget);
    await _tap(t, find.byKey(const Key('managed-runtime-details-codex')));
    expect(find.text(_codexPath), findsNothing);
    // Details never chose the runtime.
    expect(find.byKey(const Key('managed-add-panel')), findsOneWidget);
  });

  testWidgets('a second OpenCode gets a free name; a taken one is refused '
      'before anything starts', (t) async {
    final api = _fake();
    await _openSheet(t, api);
    await _tap(t, find.byKey(const Key('managed-runtime-opencode')));
    expect(find.byKey(const Key('managed-add-panel')), findsNothing);
    final name = find.byKey(const Key('managed-name'));
    expect(t.widget<TextField>(name).controller!.text, 'opencode-2');
    // Another spelling of the running host's name is the same instance.
    await t.enterText(name, 'OpenCode');
    await t.pumpAndSettle();
    expect(find.text(_en.managedNameInUse('opencode')), findsOneWidget);
    final create = find.byKey(const Key('managed-create'));
    expect(t.widget<FilledButton>(create).onPressed, isNull);
  });

  testWidgets('an unavailable runtime and Claude needing setup say so '
      'briefly; Prepare stays a single explicit action', (t) async {
    final api =
        _fake(
            hosts: const [],
            runtimes: const [
              ManagedRuntimeAvailability(
                kind: 'codex',
                ready: false,
                problem: 'codex 0.20 is older than the supported 0.120',
              ),
              ManagedRuntimeAvailability(
                kind: 'claude',
                ready: false,
                canPrepare: true,
              ),
            ],
          )
          ..claudePrepareScript.add(
            const AcpClaudeSetup(
              state: 'running',
              stage: 'downloading',
              started: true,
            ),
          );
    await _openSheet(t, api);
    expect(_status(t, 'codex'), _en.managedRuntimeUnavailable);
    expect(_status(t, 'claude'), _en.managedRuntimeNeedsSetup);
    expect(find.textContaining('older than'), findsNothing);
    await _tap(t, find.byKey(const Key('managed-runtime-details-codex')));
    expect(find.textContaining('older than'), findsOneWidget);
    await t.tap(find.byKey(const Key('managed-claude-prepare')));
    await t.pump();
    expect(api.claudePrepareStarts, 1);
    expect(find.byKey(const Key('managed-claude-progress')), findsOneWidget);
    Navigator.of(t.element(find.byKey(const Key('managed-add-panel')))).pop();
    await t.pumpAndSettle();
  });

  testWidgets('a failed runtime read offers Retry', (t) async {
    final api = _fake()..managedRuntimesError = Exception('tunnel dropped');
    await _openSheet(t, api);
    expect(find.byKey(const Key('managed-runtimes-error')), findsOneWidget);
    await _tap(t, find.byKey(const Key('managed-runtimes-retry')));
    expect(find.byKey(const Key('managed-runtime-codex')), findsOneWidget);
  });

  testWidgets('a 320 px phone at 2x text keeps the sheet padded and every '
      'Details button reachable', (t) async {
    await _openSheet(
      t,
      _fake(),
      size: const Size(320, 760),
      textScale: 2,
      locale: const Locale('zh'),
    );
    expect(t.takeException(), isNull);
    final panel = t.getRect(find.byKey(const Key('managed-add-panel')));
    expect(panel.left, greaterThanOrEqualTo(20));
    expect(320 - panel.right, greaterThanOrEqualTo(20));
    for (final kind in ['codex', 'opencode', 'claude']) {
      final details = find.byKey(Key('managed-runtime-details-$kind'));
      await t.ensureVisible(details);
      await t.pumpAndSettle();
      final box = t.getRect(details);
      expect(box.width, greaterThanOrEqualTo(40));
      expect(box.height, greaterThanOrEqualTo(40));
      expect(box.bottom, lessThanOrEqualTo(760));
    }
    await t.tap(find.byKey(const Key('managed-runtime-details-claude')));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
