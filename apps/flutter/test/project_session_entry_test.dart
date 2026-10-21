import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/screens/app_session_screen.dart';
import 'package:pocox/src/widgets/layered_navigation.dart';
import 'package:pocox/src/theme.dart';

import 'fake_bridge_api.dart';
import 'package:pocox/src/app_icons.dart';

import 'support/composer_harness.dart';
import 'support/ui_preview.dart';

class _LateProjectApi extends FakeBridgeApi {
  final project = Completer<ProjectConfig>();
  @override
  Future<ProjectConfig> metaProjectConfig(String serviceKey) => project.future;
}

Future<void> _mount(
  WidgetTester t,
  FakeBridgeApi api, {
  Size size = const Size(1280, 900),
  Brightness brightness = Brightness.light,
  String? cwd = '/work/alpha',
  bool settle = true,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  api.appThreads.addAll([
    ThreadMeta(
      id: 'a',
      preview: 'Alpha history',
      cwd: '/work/alpha',
      updatedAt: now - 30,
    ),
    ThreadMeta(
      id: 'b',
      preview: 'Beta history',
      cwd: '/work/beta',
      updatedAt: now - 60,
    ),
  ]);
  await api.appConnect(composerService, 28080);
  await t.pumpWidget(
    ProviderScope(
      overrides: [bridgeApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: brightness == Brightness.light ? lightTheme() : darkTheme(),
        home: RepaintBoundary(
          key: previewKey,
          child: AppSessionScreen(
            serviceKey: composerService,
            cwd: cwd,
            home: true,
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await t.pumpAndSettle();
  } else {
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _newIn(WidgetTester t, String path) async {
  final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(t.getCenter(find.byKey(Key('project-header-$path'))));
  await t.pumpAndSettle();
  await t.tap(find.byKey(Key('project-new-$path')));
  await mouse.removePointer();
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadPreviewFonts();
  });
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets(
    'project shortcuts preserve separate drafts, selection, order and collapse',
    (t) async {
      final api = FakeBridgeApi();
      await _mount(t, api);
      await t.enterText(composerInput, 'Alpha draft');
      const selection = TextSelection(baseOffset: 2, extentOffset: 5);
      composerController(t).selection = selection;
      await t.tap(find.byKey(const Key('project-header-/work/beta')));
      await t.pumpAndSettle();
      final betaTop = t.getTopLeft(
        find.byKey(const Key('project-header-/work/beta')),
      );
      await _newIn(t, '/work/beta');
      expect(composerController(t).text, isEmpty);
      expect(t.widget<TextField>(composerInput).focusNode!.hasFocus, isTrue);
      expect(find.text('Beta history'), findsNothing);
      expect(
        t.getTopLeft(find.byKey(const Key('project-header-/work/beta'))),
        betaTop,
      );
      await t.enterText(composerInput, 'Beta draft');
      await _newIn(t, '/work/alpha');
      expect(composerController(t).text, 'Alpha draft');
      expect(composerController(t).selection, selection);
      await _newIn(t, '/work/beta');
      expect(composerController(t).text, 'Beta draft');
      expect(
        api.appThreads,
        hasLength(2),
        reason: 'Opening a draft must not create a server thread.',
      );
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pumpAndSettle();
      expect(api.lastCwd, '/work/beta');
      expect(api.appThreads, hasLength(3));
      await _newIn(t, '/work/alpha');
      expect(composerController(t).text, 'Alpha draft');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'mobile long press selects project, closes sidebar and focuses input',
    (t) async {
      final api = FakeBridgeApi();
      await _mount(t, api, size: const Size(390, 844));
      await t.tap(find.byTooltip('Conversations').first);
      await t.pumpAndSettle();
      await t.longPress(find.byKey(const Key('project-header-/work/beta')));
      await t.pumpAndSettle();
      expect(find.text('/work/beta'), findsOneWidget);
      await t.tap(find.text('New conversation in beta'));
      await t.pumpAndSettle();
      expect(
        t.state<LayeredNavigationState>(find.byType(LayeredNavigation)).isOpen,
        isFalse,
      );
      expect(t.widget<TextField>(composerInput).focusNode!.hasFocus, isTrue);
      expect(find.text('beta'), findsWidgets);
      await t.enterText(composerInput, 'Mobile beta');
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pumpAndSettle();
      expect(api.lastCwd, '/work/beta');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'project with only running threads retains its new-session entry',
    (t) async {
      final api = FakeBridgeApi();
      await _mount(t, api);
      api.pushEvent(
        composerService,
        const AppEvent(kind: 'turn/started', threadId: 'b', raw: '{}'),
      );
      await t.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('project-header-/work/beta')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('conv-tile-b')), findsOneWidget);
      api.pushEvent(
        composerService,
        const AppEvent(kind: 'turn/completed', threadId: 'b', raw: '{}'),
      );
      await t.pumpAndSettle();
      await _newIn(t, '/work/beta');
      expect(t.widget<TextField>(composerInput).focusNode!.hasFocus, isTrue);
    },
  );

  for (final switchBeforeDefault in [false, true]) {
    testWidgets(
      'late default project preserves draft (switch: $switchBeforeDefault)',
      (t) async {
        final api = _LateProjectApi();
        await _mount(t, api, cwd: null, settle: false);
        await t.enterText(composerInput, 'Unassigned draft');
        if (switchBeforeDefault) await _newIn(t, '/work/beta');
        api.project.complete(
          const ProjectConfig(defaultProject: '/work/alpha'),
        );
        await t.pumpAndSettle();
        if (switchBeforeDefault) {
          expect(composerController(t).text, isEmpty);
          await t.enterText(composerInput, 'Explicit beta');
        } else {
          expect(composerController(t).text, 'Unassigned draft');
          await _newIn(t, '/work/beta');
          await _newIn(t, '/work/alpha');
          expect(composerController(t).text, 'Unassigned draft');
        }
        await t.pump();
        await t.tap(find.byKey(const Key('send-btn')));
        await t.pumpAndSettle();
        expect(api.lastCwd, switchBeforeDefault ? '/work/beta' : '/work/alpha');
      },
    );
  }

  testWidgets(
    'late default project discovery preserves active IME composition',
    (t) async {
      final api = _LateProjectApi();
      await _mount(t, api, cwd: null, settle: false);
      const value = TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      await t.showKeyboard(composerInput);
      t.testTextInput.updateEditingValue(value);
      await t.pump();
      api.project.complete(const ProjectConfig(defaultProject: '/work/alpha'));
      await t.pumpAndSettle();
      expect(composerController(t).value, value);
      expect(find.text('alpha'), findsWidgets);
    },
  );

  testWidgets('explicit outside-project selection wins over a late default', (
    t,
  ) async {
    final api = _LateProjectApi();
    await _mount(t, api, cwd: null, settle: false);
    await t.tap(find.byKey(const Key('project-switcher-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('project-menu-none')));
    await t.pumpAndSettle();
    api.project.complete(const ProjectConfig(defaultProject: '/work/alpha'));
    await t.pumpAndSettle();
    await t.enterText(composerInput, 'Outside any project');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.appThreads, hasLength(3));
    expect(api.lastCwd, isNull);
  });

  for (final device in [
    (name: 'phone', size: const Size(390, 844)),
    (name: 'tablet', size: const Size(820, 1180)),
    (name: 'desktop', size: const Size(1280, 900)),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('minimal new session ${device.name} $brightness', (t) async {
        debugDefaultTargetPlatformOverride = device.name == 'desktop'
            ? TargetPlatform.windows
            : TargetPlatform.android;
        try {
          await _mount(
            t,
            FakeBridgeApi(),
            size: device.size,
            brightness: brightness,
            cwd: '/work/a-project-with-a-long-name-to-check-wrapping',
          );
          expect(find.byKey(const Key('project-switcher-btn')), findsOneWidget);
          expect(find.byIcon(AppIcons.terminal_rounded), findsNothing);
          expect(
            t.getRect(composerInput).bottom,
            lessThanOrEqualTo(device.size.height),
          );
          expect(t.takeException(), isNull);
          await capturePreview(t, '${device.name}-${brightness.name}');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }
}
