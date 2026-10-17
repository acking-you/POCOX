import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/widgets/local_host_dialog.dart';

import 'fake_bridge_api.dart';

Future<void> pumpDialog(WidgetTester tester, FakeBridgeApi api) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [bridgeApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showHostingEditor(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Built-in engine stays disabled and hosting starts external Codex',
    (tester) async {
      final api = FakeBridgeApi();
      await pumpDialog(tester, api);
      final source = find.byKey(const Key('codex-source'));
      final selector = tester.widget<SegmentedButton<bool>>(source);
      expect(selector.segments.singleWhere((s) => s.value).enabled, isFalse);
      // Marked as not implemented on the segment itself.
      final l10n = lookupAppLocalizations(const Locale('zh'));
      final builtIn = find.descendant(
        of: source,
        matching: find.text(
          '${l10n.codexSourceBuiltin} · ${l10n.codexBuiltinUnavailable}',
        ),
      );
      expect(builtIn, findsOneWidget);
      // Scrolled into view first: below the fold the tap would land on the
      // page's workspace navigation instead of the disabled segment.
      await tester.ensureVisible(builtIn);
      await tester.pumpAndSettle();
      await tester.tap(builtIn);
      await tester.pumpAndSettle();
      expect(tester.widget<SegmentedButton<bool>>(source).selected, {false});
      await tester.tap(find.byKey(const Key('start-hosting-btn')));
      await tester.pumpAndSettle();
      expect(api.lastServeEmbedded, isFalse);
      expect(api.serveHosts, hasLength(1));
      expect(api.acpServeCalls, isEmpty, reason: 'the native app-server');
    },
  );

  testWidgets('Missing external binary cannot fall back to a built-in engine', (
    tester,
  ) async {
    final api = FakeBridgeApi()..codexPath = null;
    await pumpDialog(tester, api);
    await tester.tap(find.byKey(const Key('start-hosting-btn')));
    await tester.pumpAndSettle();
    expect(api.lastServeEmbedded, isNull);
    expect(api.serveHosts, isEmpty);
    expect(find.byType(LocalHostDialog), findsOneWidget);
  });

  test(
    'Legacy hosting preferences preserve settings and migrate to external',
    () {
      final prefs = AutoHostPrefs.fromJson({
        'port': 18080,
        'name': 'legacy',
        'proxy': 'http://127.0.0.1:11111',
        'binaryOverride': '/custom/codex',
        'embedded': true,
      });
      expect(prefs.embedded, isFalse);
      expect(prefs.toJson(), {
        'port': 18080,
        'name': 'legacy',
        'proxy': 'http://127.0.0.1:11111',
        'binaryOverride': '/custom/codex',
        'embedded': false,
      });
    },
  );
}
