import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/log_manager.dart';
import 'package:pocox/src/screens/log_view_screen.dart';

import 'fake_bridge_api.dart';

LogLine _line(String level, String msg, {String target = 'test', int ts = 0}) =>
    LogLine(level: level, target: target, message: msg, timestampMs: ts);

void main() {
  test(
    'controller diagnostics go through the bridge and clear native history',
    () async {
      final fake = FakeBridgeApi();
      final logs = LogManager.instance;
      logs.dispose();
      logs.initialize(fake);
      logs.record('controller', 'reconnected');
      expect(fake.logs.single.message, 'reconnected');
      expect((await logs.query()).total, 1);
      logs.clear();
      expect(fake.logs, isEmpty);
      logs.dispose();
    },
  );

  group('LogViewScreen', () {
    setUp(() {
      LogManager.instance.dispose();
      LogManager.instance.clear();
    });

    testWidgets('renders streamed log lines', (t) async {
      final fake = FakeBridgeApi();
      LogManager.instance.initialize(fake);
      fake.pushLog(_line('ERROR', 'tunnel down', target: 'serve'));

      await t.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const LogViewScreen(),
        ),
      );
      // Past the LogManager emit-coalesce window so the streamed line renders.
      await t.pump(const Duration(milliseconds: 150));

      // The page title belongs to the shared top bar; no duplicate heading is
      // rendered above the filters.
      expect(find.text('运行日志'), findsOneWidget);
      expect(find.textContaining('tunnel down'), findsOneWidget);
    });
  });
}
