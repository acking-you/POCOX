// Secondary pages that overflowed on phones, mounted with the real fonts on
// an iOS target at the sizes that broke: the services device list (it did
// not scroll), a host's session list with a takeover row, and the folder
// picker's confirmation bar. Mounting and pumping is the overflow check: an
// overflow is a FlutterError, which fails the test. Set POCOX_UI_PREVIEW_DIR
// to write the previews (`phone-pages-*`).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/screens/local_sessions_screen.dart';
import 'package:pocox/src/screens/services_screen.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/folder_tree_picker.dart';

import 'fake_bridge_api.dart';
import 'support/ui_preview.dart';

const _device = 'ackingliu-macbook-pro-m3-max';
const _app = 'pcx:$_device:app:default';
const _root = '/Users/ackingliu/rust_pro/my_pro/pocox-workspace';

/// Mount [screen] on an iOS phone of [size] at text [scale].
Future<void> _mount(
  WidgetTester t,
  FakeBridgeApi api,
  Widget screen, {
  required Size size,
  double scale = 1,
  Locale locale = const Locale('en'),
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  await t.pumpWidget(const SizedBox());
  await t.pumpWidget(
    ProviderScope(
      overrides: [bridgeApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        locale: locale,
        theme: lightTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: previewKey, child: child!),
        ),
        home: screen,
      ),
    ),
  );
  await _frames(t);
}

/// Bounded pumps: probes and pulsing status dots never settle.
Future<void> _frames(WidgetTester t, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Run [body] with an iOS target, restoring the view and platform after.
Future<void> _onIos(WidgetTester t, Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
    t.view.reset();
  }
}

/// [finder] lies wholly on a screen of [size].
void _onScreen(WidgetTester t, Finder finder, Size size, String why) {
  final rect = t.getRect(finder);
  expect(
    rect.left >= -0.5 &&
        rect.right <= size.width + 0.5 &&
        rect.bottom <= size.height + 0.5,
    isTrue,
    reason: '$why: $rect',
  );
}

void main() {
  setUpAll(() => loadPreviewFonts(always: true));

  testWidgets('a long device list scrolls on a small phone and every device '
      'opens', (t) async {
    await _onIos(t, () async {
      final devices = [
        for (var i = 0; i < 9; i++) 'device-number-$i-with-a-long-name',
      ];
      for (final (size, scale) in const [
        (Size(375, 667), 1.0),
        (Size(320, 640), 2.0),
      ]) {
        final api = FakeBridgeApi(
          config: const ConfigInfo(
            relay: 'relay-ap-southeast-1.pocox.example.com:17666',
            hasKey: true,
          ),
          services: [
            for (final d in devices)
              ServiceEntry(
                device: d,
                kind: 'app',
                name: 'default',
                key: 'pcx:$d:app:default',
              ),
          ],
        );
        await _mount(t, api, const ServicesScreen(), size: size, scale: scale);
        final last = find.byKey(Key('device-${devices.last}'));
        await t.scrollUntilVisible(last, 120);
        await t.pump();
        _onScreen(t, last, size, 'last device $size ×$scale');
        await capturePreview(t, 'phone-pages-devices-${size.width.toInt()}');
        await t.tap(last);
        await _frames(t);
        expect(find.byKey(const Key('device-back')), findsOneWidget);
      }
    });
  });

  testWidgets('a session row puts its status and takeover under the title '
      'with large text, and beside it at default text', (t) async {
    await _onIos(t, () async {
      final api = FakeBridgeApi()
        ..localSessions = const [
          LocalSession(
            threadId: 't1',
            cwd: '/Users/ackingliu/rust_pro/my_pro/pocox/apps/flutter',
            preview: 'Run the tests and explain why the services page fails',
            updatedAt: 1760000000,
            turnState: 'completed',
            heldOpen: true,
            safety: 'ownedIdle',
            allowsResume: true,
            requiresTakeover: true,
          ),
        ];
      const screen = LocalSessionsScreen(source: SessionSource.remote(_app));
      final takeover = find.byKey(const Key('resume-t1'));
      final title = find.textContaining('Run the tests');

      await _mount(t, api, screen, size: const Size(320, 640), scale: 2);
      _onScreen(t, takeover, const Size(320, 640), 'takeover');
      expect(
        t.getRect(takeover).top,
        greaterThanOrEqualTo(t.getRect(title).bottom),
        reason: 'stacked under the title',
      );
      await capturePreview(t, 'phone-pages-sessions-320-2.0');

      await _mount(t, api, screen, size: const Size(393, 852));
      expect(
        t.getRect(takeover).center.dy,
        lessThan(t.getRect(title).bottom + 12),
        reason: 'one line at default text',
      );
    });
  });

  testWidgets('the folder picker keeps its confirmation reachable with large '
      'text', (t) async {
    await _onIos(t, () async {
      for (final locale in const [Locale('en'), Locale('zh')]) {
        final api = FakeBridgeApi()
          ..projectConfigs[_app] = const ProjectConfig(projectRoots: [_root]);
        await _mount(
          t,
          api,
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: const Key('open'),
                onPressed: () => showFolderPicker(
                  context,
                  serviceKey: _app,
                  initialPath: _root,
                ),
                child: const Text('open'),
              ),
            ),
          ),
          size: const Size(320, 640),
          scale: 2,
          locale: locale,
        );
        await t.tap(find.byKey(const Key('open')));
        await _frames(t);
        final use = find.byKey(const Key('folder-use-btn'));
        _onScreen(t, use, const Size(320, 640), 'use ${locale.languageCode}');
        await capturePreview(
          t,
          'phone-pages-folder-picker-${locale.languageCode}',
        );
        await t.tap(use);
        await _frames(t);
        expect(use, findsNothing, reason: 'the folder was chosen');
      }
    });
  });
}
