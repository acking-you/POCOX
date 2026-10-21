import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/updates/update_api.dart';
import 'package:pocox/src/updates/update_controller.dart';
import 'package:pocox/src/updates/update_host.dart';
import 'package:pocox/src/updates/update_settings.dart';

import 'fake_bridge_api.dart';

UpdateState _found(
  String method, {
  String phase = 'available',
  String? announced,
  String? path,
}) => UpdateState(
  current: '0.5.0',
  phase: phase,
  method: method,
  page: 'https://github.com/acking-you/POCOX/releases/tag/v0.6.0',
  latest: '0.6.0',
  newer: true,
  size: 64000000,
  announced: announced,
  path: path,
);

void main() {
  group('one-click update', () {
    test('a restarting update quits the app once the helper waits', () async {
      final api = FakeBridgeApi()..update = _found('replace_bundle');
      var quits = 0;
      final actions = UpdateActions(
        api,
        quit: () async {
          quits++;
          return null;
        },
      );
      await actions.updateNow();
      expect(api.updateCalls, ['download', 'install']);
      expect(quits, 1);
    });

    test('a quit that is blocked is reported, not retried', () async {
      final api = FakeBridgeApi()..update = _found('installer');
      final actions = UpdateActions(
        api,
        quit: () async => 'a hosted service may still run',
      );
      await actions.updateNow();
      expect(api.updateCalls, ['download', 'install', 'report:quit']);
    });

    test('nothing installs when the download did not verify', () async {
      final api = FakeBridgeApi()
        ..update = _found('replace_bundle')
        ..downloadResult = _found('replace_bundle', phase: 'failed');
      var quits = 0;
      await UpdateActions(
        api,
        quit: () async {
          quits++;
          return null;
        },
      ).updateNow();
      expect(api.updateCalls, ['download']);
      expect(quits, 0);
    });

    test('Android hands the package to the system installer', () async {
      final api = FakeBridgeApi()
        ..update = _found('system_installer')
        ..installResult = _found(
          'system_installer',
          phase: 'opened',
          path: '/data/updates/app.apk',
        );
      final installed = <String>[];
      await UpdateActions(
        api,
        systemInstall: (path) async => installed.add(path),
      ).updateNow();
      expect(installed, ['/data/updates/app.apk']);
      expect(api.updateCalls, ['download', 'install']);
    });

    test('a device with nothing to install opens the release page', () async {
      final api = FakeBridgeApi()..update = _found('release_page');
      final opened = <String>[];
      await UpdateActions(
        api,
        open: (url) async => opened.add(url),
      ).updateNow();
      expect(opened, [api.update.page]);
      expect(api.updateCalls, isEmpty);
    });
  });

  Widget app(FakeBridgeApi api, {required Widget child}) => ProviderScope(
    overrides: [
      bridgeApiProvider.overrideWithValue(api),
      updateActionsProvider.overrideWithValue(
        UpdateActions(api, quit: () async => null),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: UpdateHost(child: Scaffold(body: child)),
    ),
  );

  testWidgets('a new release is offered once, and its button updates', (
    tester,
  ) async {
    final api = FakeBridgeApi();
    await tester.pumpWidget(app(api, child: const UpdateSettings()));
    await tester.pump();
    expect(api.updateCalls, ['background']);
    expect(find.byKey(const Key('update-check')), findsOneWidget);

    api.setUpdate(_found('replace_bundle'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('toast-action')), findsOneWidget);
    expect(api.updateCalls, contains('announce:0.6.0'));

    // The same release again (a later check) is not offered again.
    api.setUpdate(_found('replace_bundle', announced: '0.6.0'));
    await tester.pump();
    expect(
      api.updateCalls.where((call) => call.startsWith('announce')),
      hasLength(1),
    );

    await tester.tap(find.byKey(const Key('update-now')));
    await tester.pump();
    expect(api.updateCalls, containsAllInOrder(['download', 'install']));
  });

  testWidgets('a download shows its progress and can be cancelled', (
    tester,
  ) async {
    final api = FakeBridgeApi()
      ..update = const UpdateState(
        current: '0.5.0',
        phase: 'downloading',
        method: 'replace_bundle',
        page: 'https://github.com/acking-you/POCOX/releases/tag/v0.6.0',
        latest: '0.6.0',
        newer: true,
        size: 1000,
        received: 370,
        announced: '0.6.0',
      );
    await tester.pumpWidget(app(api, child: const UpdateSettings()));
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('update-now')),
    );
    expect(button.onPressed, isNull);
    expect(find.textContaining('37%'), findsOneWidget);
    await tester.tap(find.byKey(const Key('update-cancel')));
    expect(api.updateCalls, contains('cancel'));
  });
}
