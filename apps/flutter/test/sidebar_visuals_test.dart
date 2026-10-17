// The conversation sidebar's look, held to what it must say. The open row is
// a neutral raised plate announced as selected, with no second accent. A
// running row turns and sweeps while it runs; with reduced motion it holds
// still and says "running" in words. The fold control sits in the title
// gutter, so parents and plain rows share one title column. It folds by
// keyboard, announces its expanded state, and in RTL mirrors to the start
// side, with large text kept whole. Until the host first lists its
// conversations, the pane says it is loading rather than empty.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/loading.dart';
import 'package:pocket_codex/src/widgets/running_sheen.dart';
import 'package:pocket_codex/src/widgets/status_dots.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';
import 'support/ui_preview.dart';
import 'package:pocket_codex/src/app_icons.dart';

const _service = 'pcx:sidebar:app:default';
const _parent = ThreadMeta(
  id: 'parent',
  preview: 'Main work',
  cwd: '/repo',
  updatedAt: 1,
);
const _solo = ThreadMeta(
  id: 'solo',
  preview: 'Solo work',
  cwd: '/repo',
  updatedAt: 2,
);
const _reviewer = ThreadMeta(
  id: 'reviewer',
  preview: 'Approval review',
  cwd: '/repo',
  updatedAt: 3,
  parentThreadId: 'parent',
  threadSource: 'guardian_review',
);

/// Bounded pumping: a running row animates for as long as it runs.
Future<void> _frames(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<FakeBridgeApi> _mount(
  WidgetTester t, {
  bool reduceMotion = false,
  double textScale = 1,
  TextDirection direction = TextDirection.ltr,
  ThemeData? theme,
  double width = 1280,
}) async {
  t.view.physicalSize = Size(width, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final api = FakeBridgeApi()
    ..appThreads.clear()
    ..appThreads.addAll([_reviewer, _solo, _parent]);
  await api.appConnect(_service, 28080);
  await t.pumpWidget(
    host(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduceMotion,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Directionality(
            textDirection: direction,
            child: const AppSessionScreen(
              serviceKey: _service,
              threadId: 'parent',
              home: true,
            ),
          ),
        ),
      ),
      api,
      theme: theme ?? lightTheme(),
    ),
  );
  await _frames(t);
  return api;
}

Future<void> _turn(FakeBridgeApi api, WidgetTester t, String kind) async {
  api.pushEvent(
    _service,
    AppEvent(kind: kind, threadId: 'solo', raw: '{"turn":{"id":"turn"}}'),
  );
  await _frames(t);
}

Finder _tile(String id) => find.byKey(Key('conv-tile-$id'));

Finder _title(String id, String text) =>
    find.descendant(of: _tile(id), matching: find.text(text));

final _toggle = find.byKey(const Key('session-children-parent'));
final _glyph = find.descendant(
  of: _toggle,
  matching: find.byIcon(AppIcons.keyboard_arrow_right),
);

double _turns(WidgetTester t) => t
    .widget<AnimatedRotation>(
      find.descendant(of: _toggle, matching: find.byType(AnimatedRotation)),
    )
    .turns;

void main() {
  setUpAll(() => loadPreviewFonts(always: true));
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('the pane is loading, not empty, until the host lists', (
    t,
  ) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final list = Completer<void>();
    final api = FakeBridgeApi()
      ..appThreads.clear()
      ..appThreads.add(_solo)
      ..threadListGate = list.future;
    await api.appConnect(_service, 28080);
    // The open conversation reads its own metadata first; that is no listing.
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: _service,
          threadId: 'solo',
          home: true,
        ),
        api,
      ),
    );
    await _frames(t);
    expect(find.byType(ConversationListSkeleton), findsOneWidget);
    expect(find.text('暂无会话'), findsNothing, reason: 'loading, not empty');

    list.complete();
    await t.pumpAndSettle();
    expect(find.byType(ConversationListSkeleton), findsNothing);
    expect(find.byKey(const Key('conv-tile-solo')), findsOneWidget);
  });

  testWidgets('the fold control sits in the title gutter and folds by '
      'keyboard', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final semantics = t.ensureSemantics();
    try {
      await _mount(t);
      final main = _title('parent', 'Main work');
      expect(
        t.getTopLeft(main).dx,
        t.getTopLeft(_title('solo', 'Solo work')).dx,
        reason: 'parents and plain rows share one title column',
      );
      expect(t.getSize(_toggle), const Size(22, 22));
      expect(
        t.getRect(_toggle).right,
        lessThanOrEqualTo(t.getTopLeft(main).dx),
      );
      expect(
        t.getCenter(_toggle).dy,
        moreOrLessEquals(t.getCenter(_tile('parent')).dy, epsilon: 0.5),
      );
      expect(
        t.getSemantics(_glyph),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          hasExpandedState: true,
          isExpanded: false,
        ),
      );
      expect(find.byKey(const Key('session-tree-reviewer')), findsNothing);

      Focus.of(t.element(_glyph)).requestFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(t);
      expect(find.byKey(const Key('session-tree-reviewer')), findsOneWidget);
      expect(t.widget<IconButton>(_toggle).isSelected, isTrue);
      expect(_turns(t), 0.25);
      expect(
        t.getSemantics(_glyph),
        isSemantics(hasExpandedState: true, isExpanded: true),
      );
      // The child indents by half a gutter, its edge under the parent's
      // fold control, and its caption starts on its title column.
      final child = t.getTopLeft(_tile('reviewer')).dx;
      expect(child - t.getTopLeft(_tile('parent')).dx, 14);
      expect(child, moreOrLessEquals(t.getCenter(_toggle).dx, epsilon: 0.5));
      expect(
        t
            .getTopLeft(
              find.descendant(
                of: find.byKey(const Key('session-tree-reviewer')),
                matching: find.text('模型审批'),
              ),
            )
            .dx,
        t.getTopLeft(_title('reviewer', 'Approval review')).dx,
      );

      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await _frames(t);
      expect(find.byKey(const Key('session-tree-reviewer')), findsNothing);
      expect(_turns(t), 0);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('touch keeps a finger-sized fold target', (t) async {
    await _mount(t);
    expect(t.getSize(_toggle), const Size(44, 44));
    // On the row's own plate, so a selected or hovered row is one shape.
    final plate = t.getRect(_tile('parent'));
    expect(plate.left, lessThanOrEqualTo(t.getRect(_toggle).left));
    expect(plate.contains(t.getCenter(_toggle)), isTrue);
    await t.tap(_toggle);
    await _frames(t);
    expect(find.byKey(const Key('session-tree-reviewer')), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  for (final (name, theme) in [
    ('light', lightTheme()),
    ('dark', darkTheme()),
  ]) {
    testWidgets('$name: the open row is a raised neutral plate, announced as '
        'selected', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final semantics = t.ensureSemantics();
      try {
        await _mount(t, theme: theme);
        final scheme = theme.colorScheme;
        final open = t.widget<Material>(_tile('parent'));
        expect(open.color, sidebarSelection(scheme));
        expect(open.elevation, 1);
        expect(
          (open.shape! as RoundedRectangleBorder).side.color,
          sidebarSelectionEdge(scheme),
        );
        final idle = t.widget<Material>(_tile('solo'));
        expect(idle.color, Colors.transparent);
        expect(idle.elevation, 0);
        expect(
          t.getSemantics(_title('parent', 'Main work')),
          isSemantics(isSelected: true),
        );
        expect(
          t.getSemantics(_title('solo', 'Solo work')),
          isSemantics(isSelected: false),
        );
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  for (final reduce in [false, true]) {
    testWidgets(
      reduce
          ? 'reduced motion: a running row holds still and says so'
          : 'a running row turns and sweeps while it runs',
      (t) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        final semantics = t.ensureSemantics();
        try {
          final api = await _mount(t, reduceMotion: reduce);
          final idleTickers = t.binding.transientCallbackCount;
          expect(find.byType(RunningSheen), findsNothing);

          await _turn(api, t, 'turn/started');
          final mark = find.descendant(
            of: _tile('solo'),
            matching: find.byType(PulsingDot),
          );
          expect(mark, findsOneWidget);
          expect(t.widget<PulsingDot>(mark).orbit, isTrue);
          expect(
            find.descendant(
              of: _tile('solo'),
              matching: find.byType(RunningSheen),
            ),
            findsOneWidget,
          );
          expect(find.bySemanticsLabel(RegExp('运行中')), findsWidgets);
          final label = find.descendant(
            of: _tile('solo'),
            matching: find.byKey(const Key('conv-running-label')),
          );
          if (reduce) {
            expect(t.widget<Text>(label).data, '运行中…');
            expect(
              t.binding.transientCallbackCount,
              idleTickers,
              reason: 'nothing loops with reduced motion',
            );
          } else {
            expect(label, findsNothing, reason: 'the orbit says it');
            expect(
              t.binding.transientCallbackCount,
              greaterThan(idleTickers),
              reason: 'the orbit and the sheen are moving',
            );
          }

          await _turn(api, t, 'turn/completed');
          expect(
            find.descendant(
              of: _tile('solo'),
              matching: find.byType(PulsingDot),
            ),
            findsNothing,
          );
          expect(find.byType(RunningSheen), findsNothing);
          expect(t.binding.transientCallbackCount, idleTickers);
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        } finally {
          semantics.dispose();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  testWidgets('narrow sidebar with large text keeps titles above metadata', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final api = await _mount(t, width: 800, textScale: 2, reduceMotion: true);
      await _turn(api, t, 'turn/started');
      final title = _title('solo', 'Solo work');
      final label = find.descendant(
        of: _tile('solo'),
        matching: find.byKey(const Key('conv-running-label')),
      );
      expect(t.getSize(title).width, greaterThan(100));
      expect(
        t.getTopLeft(label).dy,
        greaterThanOrEqualTo(t.getBottomLeft(title).dy),
      );
      await t.tap(_toggle);
      await _frames(t);
      expect(
        t.getSize(_title('reviewer', 'Approval review')).width,
        greaterThan(100),
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('reduced-motion window resizing keeps the sidebar and composer '
      'laid out without zero-duration size animation errors', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await _mount(t, width: 800, textScale: 2, reduceMotion: true);
      for (final width in [1280.0, 800.0]) {
        t.view.physicalSize = Size(width, 900);
        await _frames(t);
        expect(
          t.getSize(_title('parent', 'Main work')).width,
          greaterThan(100),
        );
        expect(t.takeException(), isNull);
      }
      await t.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('RTL at 2× text keeps rows whole, the fold control on the start '
      'side and the running word bounded', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final api = await _mount(
        t,
        textScale: 2,
        direction: TextDirection.rtl,
        reduceMotion: true,
      );
      await _turn(api, t, 'turn/started');
      expect(
        t.getRect(_toggle).left,
        greaterThanOrEqualTo(t.getRect(_title('parent', 'Main work')).right),
      );
      final mirror = find.ancestor(
        of: _glyph,
        matching: find.byWidgetPredicate(
          (widget) => widget is Transform && widget.transform.entry(0, 0) == -1,
        ),
      );
      expect(
        mirror,
        findsOneWidget,
        reason: 'the closed glyph points to start',
      );
      await t.tap(_toggle);
      await _frames(t);
      expect(
        _turns(t),
        -0.25,
        reason: 'the mirrored glyph turns to point down',
      );
      expect(
        t.getTopRight(_tile('parent')).dx - t.getTopRight(_tile('reviewer')).dx,
        14,
      );
      final label = find.descendant(
        of: _tile('solo'),
        matching: find.byKey(const Key('conv-running-label')),
      );
      expect(t.getSize(label).width, lessThan(t.getSize(_tile('solo')).width));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
