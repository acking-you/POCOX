// The phone session screen's layered navigation, end to end, and the
// tablet/desktop layouts it must leave alone.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/layered_navigation.dart';

import 'fake_bridge_api.dart';
import 'support/ui_preview.dart';

const _service = 'pcx:host:app:default';
const _phone = Size(390, 844);
final _input = find.byKey(const Key('composer-input'));

LayeredNavigationState _nav(WidgetTester t) =>
    t.state<LayeredNavigationState>(find.byType(LayeredNavigation));

Future<FakeBridgeApi> _mount(WidgetTester t, {Size size = _phone}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  final api = FakeBridgeApi();
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  const projects = ['/work/pocket-codex', '/work/relay', '/work/notes'];
  const titles = [
    'Refine the mobile sidebar',
    'Relay reconnect after sleep',
    'Draft release notes',
    'Investigate flaky history test',
    'Composer keyboard spacing',
    'Theme contrast audit',
  ];
  for (var i = 0; i < 30; i++) {
    api.appThreads.add(
      ThreadMeta(
        id: 't$i',
        preview: titles[i % titles.length],
        cwd: projects[i % projects.length],
        updatedAt: now - 60 * (i + 1) - (i > 5 ? 86400 : 0),
      ),
    );
  }
  await api.appConnect(_service, 28080);
  await t.pumpWidget(
    ProviderScope(
      overrides: [bridgeApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: lightTheme(),
        home: const AppSessionScreen(serviceKey: _service, home: true),
      ),
    ),
  );
  await t.pumpAndSettle();
  return api;
}

List<String> _recordHaptics(WidgetTester t) {
  final calls = <String>[];
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        calls.add((call.arguments as String).split('.').last);
      }
      return null;
    },
  );
  addTearDown(
    () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return calls;
}

/// Drag from the leading edge to [fraction] of the width and hold.
Future<TestGesture> _edgeDrag(WidgetTester t, double fraction) async {
  final width = t.view.physicalSize.width;
  final g = await t.startGesture(Offset(10, t.view.physicalSize.height / 2));
  for (var i = 0; i < 10; i++) {
    await g.moveBy(Offset(fraction * width / 10, 0));
    await t.pump(const Duration(milliseconds: 16));
  }
  await t.pump(const Duration(milliseconds: 200));
  return g;
}

void main() {
  // Real fonts always: the tablet check measures whether a label fits.
  setUpAll(() => loadPreviewFonts(always: true));
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('a finger-tracked edge swipe opens the full-screen sidebar; a '
      'conversation tap closes it and opens the conversation', (t) async {
    final haptics = _recordHaptics(t);
    await _mount(t);
    await t.enterText(_input, 'unsent draft');
    await t.pump();
    // Hidden: offstage, not just covered.
    expect(find.byKey(const Key('new-conversation-btn')), findsNothing);
    final g = await _edgeDrag(t, 0.7);
    expect(haptics, ['lightImpact']);
    expect(_nav(t).progress, greaterThan(0.6));
    await g.up();
    await t.pumpAndSettle();
    expect(_nav(t).isOpen, isTrue);
    expect(haptics, ['lightImpact', 'mediumImpact']);
    // Full screen: the sidebar spans the width.
    expect(
      t.getSize(find.byKey(const Key('phone-sidebar'))).width,
      _phone.width,
    );
    expect(find.byKey(const Key('new-conversation-btn')), findsOneWidget);

    // Closing by its own control returns to the same draft.
    await t.tap(find.byKey(const Key('sidebar-close-btn')));
    await t.pumpAndSettle();
    expect(_nav(t).isOpen, isFalse);
    expect(t.widget<TextField>(_input).controller!.text, 'unsent draft');

    await t.tap(find.byKey(const Key('sidebar-open-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('conv-tile-t1')));
    await t.pumpAndSettle();
    expect(_nav(t).isOpen, isFalse);
    expect(find.text('Relay reconnect after sleep'), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets('a tablet keeps a readable inline sidebar', (t) async {
    await _mount(t, size: const Size(834, 1194));
    expect(find.byType(LayeredNavigation), findsNothing);
    // The default 280 px pane fits beside a 480 px chat on touch, so the
    // finger-sized pill keeps its whole label.
    final pill = find.byKey(const Key('new-conversation-btn'));
    expect(t.getSize(pill).width, greaterThanOrEqualTo(250));
    final label = t.renderObject<RenderParagraph>(
      find.descendant(of: pill, matching: find.text('New conversation')),
    );
    expect(label.didExceedMaxLines, isFalse);
    expect(t.takeException(), isNull);
  });

  testWidgets('the desktop layout is unchanged', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await _mount(t, size: const Size(1280, 860));
      expect(find.byType(LayeredNavigation), findsNothing);
      // Desktop keeps its source-list row, not the touch pill.
      expect(
        t.getSize(find.byKey(const Key('new-conversation-btn'))).height,
        lessThan(40),
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
