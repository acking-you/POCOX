import 'support/native_diff_fixture.dart';
import 'package:pocox/src/git_diff.dart';
// The conversation's status bar on phones: state, model, clock, branch and
// change counts on one line, with real fonts. It used to overflow once a
// branch and its counts were shown beside the model.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/screens/app_session_screen.dart';
import 'package:pocox/src/theme.dart';

import 'fake_bridge_api.dart';
import 'support/ui_preview.dart';

const _service = 'pcx:mac:app:default';

DiffModel _diff(int added, int removed) => diffFixture(
  'lib/x.dart',
  added: [for (var i = 0; i < added; i++) 'new $i'],
  removed: [for (var i = 0; i < removed; i++) 'old $i'],
);

Future<void> _mount(
  WidgetTester t, {
  required Size size,
  required double scale,
  required bool running,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  final api = FakeBridgeApi(
    config: const ConfigInfo(relay: 'relay.example.com:7666', hasKey: true),
  );
  api.modelLists[_service] = const [
    ModelInfo(
      id: 'gpt-6-astra',
      displayName: 'GPT-6-Astra Extended Reasoning Preview',
      description: '',
      supportedReasoningEfforts: ['xhigh'],
      defaultReasoningEffort: 'xhigh',
    ),
  ];
  api.gitDiff = _diff(554, 248);
  api.readResult = ThreadHistory(
    running: running,
    activeTurnId: running ? 'turn-1' : null,
    branch: 'codex/fix-theme-and-macos-notarization-flow',
    cwd: '/work/TSearchEngine',
    model: 'gpt-6-astra',
    items: const [
      ThreadItem(
        id: 'u1',
        turnId: 'turn-1',
        itemType: 'userMessage',
        title: '',
        text: '拉取最新更改',
      ),
    ],
  );
  await api.appConnect(_service, 1);
  await t.pumpWidget(
    ProviderScope(
      overrides: [bridgeApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        locale: const Locale('zh'),
        theme: lightTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const AppSessionScreen(serviceKey: _service, threadId: 't1'),
      ),
    ),
  );
  // Bounded: a running turn's clock never settles.
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() => loadPreviewFonts(always: true));
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('a long branch, its counts and the model share one line on a '
      'phone without overflowing', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      for (final (size, scale, running) in const [
        (Size(393, 852), 1.0, false),
        (Size(393, 852), 1.0, true),
        (Size(320, 640), 2.0, true),
      ]) {
        // An overflow is a FlutterError, which fails the test by itself.
        await _mount(t, size: size, scale: scale, running: running);
        final at = '$size ×$scale running=$running';
        final branch = find.byKey(const Key('status-branch-chip'));
        expect(branch, findsOneWidget, reason: at);
        // The counts, the reason to open the review, always show whole.
        expect(
          find.descendant(of: branch, matching: find.text('+554')),
          findsOneWidget,
          reason: at,
        );
        expect(
          t.getRect(branch).right,
          lessThanOrEqualTo(size.width),
          reason: at,
        );
        if (!running && scale == 1) {
          // With room to spare the model stays beside the branch.
          expect(
            find.byKey(const Key('active-model-chip')),
            findsOneWidget,
            reason: at,
          );
        }
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
      t.view.reset();
    }
  });
}
