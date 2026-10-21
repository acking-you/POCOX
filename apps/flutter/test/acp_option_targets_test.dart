// ACP model/effort controls bound to the conversation they were opened for:
// a menu or searchable list left open across a conversation, connection,
// capability or catalog change must not change any session. Also: the
// controls as accessible, operable semantics nodes; the search list above a
// phone keyboard; and a prepared session that completes after the view
// became read-only or lost its host.

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show SemanticsAction;

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart'
    as fsel;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/screens/app_session/agent_session_options.dart';
import 'package:pocox/src/screens/app_session/option_picker.dart';
import 'package:pocox/src/screens/app_session_screen.dart';
import 'package:pocox/src/theme.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/screen_harness.dart';
import 'package:pocox/src/app_icons.dart';

import 'support/ui_preview.dart';
import 'package:pocox/src/widgets/adaptive_sheet.dart';

const _acp = 'pcx:dev:acp:agent';

final _caps = negotiatedAcpCapabilities(
  providerName: 'Fixture Agent',
  profileId: 'fixture',
);

/// A model option with [count] values `p/vendor/m<i>` and an effort option.
SessionSettings _settings({int count = 4, String current = 'p/vendor/m0'}) =>
    SessionSettings(
      configOptions: [
        SessionConfigOption(
          id: 'model',
          name: 'Model',
          category: 'model',
          currentValue: current,
          values: [
            for (var i = 0; i < count; i++)
              SessionConfigValue(
                value: 'p/vendor/m$i',
                name: 'Provider Name/Model number $i',
              ),
          ],
        ),
        const SessionConfigOption(
          id: 'effort',
          name: 'Effort',
          category: 'thought_level',
          currentValue: 'default',
          values: [
            SessionConfigValue(value: 'default', name: 'default'),
            SessionConfigValue(value: 'high', name: 'high'),
          ],
        ),
      ],
    );

FakeBridgeApi _api({int count = 4}) {
  final api = FakeBridgeApi()..acpCapabilities[_acp] = _caps;
  for (final thread in ['ses-a', 'ses-b']) {
    api.sessionSettings['$_acp|$thread'] = _settings(count: count);
  }
  api.appThreads.addAll(const [
    ThreadMeta(id: 'ses-a', preview: 'A', cwd: '/work/alpha', updatedAt: 2),
    ThreadMeta(id: 'ses-b', preview: 'B', cwd: '/work/alpha', updatedAt: 1),
  ]);
  return api;
}

Future<void> _frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _open(
  WidgetTester t,
  FakeBridgeApi api, {
  String? thread,
  String? cwd,
  Size size = const Size(1400, 900),
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await api.appConnect(_acp, 28080);
  await t.pumpWidget(
    host(
      AppSessionScreen(serviceKey: _acp, threadId: thread, cwd: cwd),
      api,
      locale: const Locale('en'),
    ),
  );
  await _frames(t);
}

/// Open [option]'s menu or list; the caller completes the choice later.
Future<void> _openChip(WidgetTester t, String option) async {
  await t.ensureVisible(find.byKey(Key('agent-config-$option')));
  await t.tap(find.byKey(Key('agent-config-$option')));
  await t.pumpAndSettle();
}

/// Choose [value] in whichever picker is open, and let its route close.
/// Bounded frames, not `pumpAndSettle`: a running turn animates for as long
/// as it runs, and the menu/list routes close well within them.
Future<void> _choose(WidgetTester t, String value) async {
  final listed = find.byKey(Key('agent-option-value-$value'));
  final target = listed.evaluate().isNotEmpty
      ? listed
      : find.byWidgetPredicate(
          (w) => w is ChoiceRow<String> && w.value == value,
        );
  expect(target, findsOneWidget);
  await t.ensureVisible(target);
  await t.pump();
  await t.tap(target);
  await _frames(t);
  expect(find.byType(ChoiceRow<String>), findsNothing);
  expect(find.byKey(const Key('agent-option-list')), findsNothing);
}

/// Switch to conversation `ses-b` while a picker is still open. The picker's
/// route covers the sidebar, so the tile is activated through its own tap
/// callback, the same path a click takes.
Future<void> _switchConversationBehindPicker(WidgetTester t) async {
  final tile = find.byKey(const Key('conv-tile-ses-b'), skipOffstage: false);
  expect(tile, findsOneWidget);
  final ink = t.widget<InkWell>(
    find.descendant(of: tile, matching: find.byType(InkWell)).first,
  );
  ink.onTap!();
  await _frames(t);
}

/// Perform the semantics tap action of the node [finder] renders.
void _semanticsTap(WidgetTester t, Finder finder) {
  final node = t.getSemantics(finder);
  t
      .renderObject(finder)
      .owner!
      .semanticsOwner!
      .performAction(node.id, SemanticsAction.tap);
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  for (final (label, count) in [('short menu', 4), ('searchable list', 40)]) {
    group(label, () {
      testWidgets('a picker opened in A and answered after switching to B '
          'changes neither', (t) async {
        final api = _api(count: count);
        await _open(t, api, thread: 'ses-a');
        await _openChip(t, 'model');
        await _switchConversationBehindPicker(t);
        await _choose(t, 'p/vendor/m2');
        await _frames(t);
        expect(api.sessionConfigCalls, isEmpty);
      });

      testWidgets('a picker answered after the host connection dropped '
          'sends nothing', (t) async {
        final api = _api(count: count);
        await _open(t, api, thread: 'ses-a');
        await _openChip(t, 'model');
        api.pushEvent(
          _acp,
          const AppEvent(kind: 'acp/host/state', raw: '{"connected":false}'),
        );
        await _frames(t);
        await _choose(t, 'p/vendor/m2');
        await _frames(t);
        expect(api.sessionConfigCalls, isEmpty);
      });

      testWidgets('a picker answered after the host generation changed sends '
          'nothing', (t) async {
        final api = _api(count: count);
        await _open(t, api, thread: 'ses-a');
        await _openChip(t, 'model');
        api.pushEvent(
          _acp,
          const AppEvent(
            kind: 'acp/host/state',
            raw: '{"generation":2,"connected":true}',
          ),
        );
        await _frames(t);
        await _choose(t, 'p/vendor/m2');
        await _frames(t);
        expect(api.sessionConfigCalls, isEmpty);
      });

      testWidgets('a picker answered once a turn runs sends nothing', (
        t,
      ) async {
        final api = _api(count: count);
        await _open(t, api, thread: 'ses-a');
        await _openChip(t, 'model');
        api.pushEvent(
          _acp,
          const AppEvent(
            kind: 'turn/started',
            threadId: 'ses-a',
            raw: '{"threadId":"ses-a","turnId":"T","turn":{"id":"T"}}',
          ),
        );
        await _frames(t);
        await _choose(t, 'p/vendor/m2');
        await _frames(t);
        expect(api.sessionConfigCalls, isEmpty);
        // While running, the chip itself is disabled.
        final handle = t.ensureSemantics();
        await t.pump();
        expect(
          t.getSemantics(find.byKey(const Key('agent-config-model'))),
          isSemantics(
            isButton: true,
            hasEnabledState: true,
            isEnabled: false,
            hasTapAction: false,
          ),
        );
        handle.dispose();
      });

      testWidgets('a value the agent stopped advertising is not sent', (
        t,
      ) async {
        final api = _api(count: count);
        await _open(t, api, thread: 'ses-a');
        await _openChip(t, 'model');
        // The agent replaces its catalog: m2 is gone.
        api.sessionSettings['$_acp|ses-a'] = _settings(count: 2);
        api.pushEvent(
          _acp,
          const AppEvent(
            kind: 'acp/session/updated',
            threadId: 'ses-a',
            raw: '{}',
          ),
        );
        await _frames(t);
        await _choose(t, 'p/vendor/m2');
        await _frames(t);
        expect(api.sessionConfigCalls, isEmpty);
      });

      testWidgets('the still-current conversation accepts the change', (
        t,
      ) async {
        final api = _api(count: count);
        await _open(t, api, thread: 'ses-a');
        await _openChip(t, 'model');
        await _choose(t, 'p/vendor/m2');
        await _frames(t);
        expect(api.sessionConfigCalls, [('ses-a', 'model', 'p/vendor/m2')]);
      });
    });
  }

  testWidgets('a legacy mode menu answered after switching is ignored', (
    t,
  ) async {
    final api = _api();
    for (final thread in ['ses-a', 'ses-b']) {
      api.sessionSettings['$_acp|$thread'] = const SessionSettings(
        currentMode: 'ask',
        modes: [
          SessionMode(id: 'ask', name: 'Ask'),
          SessionMode(id: 'code', name: 'Code'),
        ],
      );
    }
    await _open(t, api, thread: 'ses-a');
    await t.tap(find.byKey(const Key('agent-mode')));
    await t.pumpAndSettle();
    await _switchConversationBehindPicker(t);
    await _choose(t, 'code');
    await _frames(t);
    expect(api.sessionConfigCalls, isEmpty);
  });

  group('semantics', () {
    testWidgets('an option chip is one operable node with its full label', (
      t,
    ) async {
      final handle = t.ensureSemantics();
      final api = _api();
      await _open(t, api, thread: 'ses-a');
      final chip = find.byKey(const Key('agent-config-model'));
      expect(
        t.getSemantics(chip),
        isSemantics(
          label: 'Model: Provider Name/Model number 0',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      // The label is announced once: no tooltip or text child duplicates it.
      expect(
        find.bySemanticsLabel('Model: Provider Name/Model number 0'),
        findsOneWidget,
      );
      // Invoking the action opens the menu.
      _semanticsTap(t, chip);
      await t.pumpAndSettle();
      expect(find.byType(ChoiceRow<String>), findsNWidgets(4));
      handle.dispose();
    });

    testWidgets('a searchable chip opens its list through semantics', (
      t,
    ) async {
      final handle = t.ensureSemantics();
      final api = _api(count: 40);
      await _open(t, api, thread: 'ses-a');
      _semanticsTap(t, find.byKey(const Key('agent-config-model')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('agent-option-search')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('keyboard focus and Enter open the menu once', (t) async {
      final api = _api();
      await _open(t, api, thread: 'ses-a');
      final chip = find.byKey(const Key('agent-config-model'));
      // Focus the chip's own control (the InkWell's focus node).
      final face = find
          .descendant(of: chip, matching: find.byType(Container))
          .first;
      Focus.of(t.element(face)).requestFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(find.byType(ChoiceRow<String>), findsNWidgets(4));
    });
  });

  group('search list above the keyboard', () {
    for (final size in [const Size(320, 640), const Size(390, 844)]) {
      testWidgets('${size.width.toInt()} wide: results stay reachable', (
        t,
      ) async {
        final api = _api(count: 60);
        await _open(t, api, thread: 'ses-a', size: size);
        await _openChip(t, 'model');
        // The software keyboard takes the lower 40% of the screen.
        final keyboard = size.height * 0.4;
        t.view.viewInsets = FakeViewPadding(bottom: keyboard);
        addTearDown(t.view.resetViewInsets);
        await t.pumpAndSettle();
        final top = size.height - keyboard;
        final search = t.getRect(find.byKey(const Key('agent-option-search')));
        expect(search.bottom, lessThanOrEqualTo(top));
        final list = t.getRect(find.byKey(const Key('agent-option-list')));
        expect(list.bottom, lessThanOrEqualTo(top + 0.5));
        // Narrow the list, scroll to a far result above the keyboard, pick it.
        await t.enterText(find.byKey(const Key('agent-option-search')), 'm5');
        await t.pumpAndSettle();
        final row = find.byKey(const Key('agent-option-value-p/vendor/m59'));
        // `scrollUntilVisible` stops once any part of the row is in the
        // viewport; then reveal the whole row inside the list's viewport.
        await t.scrollUntilVisible(
          row,
          60,
          scrollable: find.descendant(
            of: find.byKey(const Key('agent-option-list')),
            matching: find.byType(Scrollable),
          ),
        );
        await t.ensureVisible(row);
        await t.pumpAndSettle();
        final shown = t.getRect(row);
        final viewport = t.getRect(find.byKey(const Key('agent-option-list')));
        expect(shown.top, greaterThanOrEqualTo(viewport.top - 0.5));
        expect(shown.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
        // The whole row is above the keyboard...
        expect(shown.bottom, lessThanOrEqualTo(top + 0.5));
        // ...and a tap at its centre reaches it: a missed hit fails here.
        expect(row.hitTestable(), findsOneWidget, reason: 'the row is hit');
        await t.tap(row);
        await t.pumpAndSettle();
        expect(api.sessionConfigCalls, [('ses-a', 'model', 'p/vendor/m59')]);
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('no matches stays readable above the keyboard', (t) async {
      final api = _api(count: 60);
      await _open(t, api, thread: 'ses-a', size: const Size(320, 640));
      await _openChip(t, 'model');
      t.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(t.view.resetViewInsets);
      await t.enterText(find.byKey(const Key('agent-option-search')), 'zzz');
      await t.pumpAndSettle();
      final empty = t.getRect(find.byKey(const Key('agent-option-no-match')));
      expect(empty.bottom, lessThanOrEqualTo(640 - 260));
      expect(t.takeException(), isNull);
    });

    testWidgets('a long catalog builds visible rows only and reaches its '
        'last value', (t) async {
      const count = 3000;
      final api = _api(count: count);
      await _open(t, api, thread: 'ses-a');
      await _openChip(t, 'model');
      final tiles = find.descendant(
        of: find.byKey(const Key('agent-option-list')),
        matching: find.byType(ListTile, skipOffstage: false),
      );
      expect(tiles.evaluate().length, lessThan(100), reason: 'built lazily');
      // The selected value is marked; the whole catalog stays reachable.
      expect(
        find.descendant(
          of: find.byKey(const Key('agent-option-value-p/vendor/m0')),
          matching: find.byIcon(AppIcons.check),
        ),
        findsOneWidget,
      );
      final last = find.byKey(Key('agent-option-value-p/vendor/m${count - 1}'));
      await t.scrollUntilVisible(
        last,
        2000,
        maxScrolls: 200,
        scrollable: find.descendant(
          of: find.byKey(const Key('agent-option-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await t.ensureVisible(last);
      await t.pumpAndSettle();
      expect(tiles.evaluate().length, lessThan(100), reason: 'still lazy');
      expect(
        t.getSemantics(last),
        isSemantics(label: 'Provider Name/Model number ${count - 1}'),
      );
      await t.tap(last);
      await t.pumpAndSettle();
      expect(api.sessionConfigCalls, [
        ('ses-a', 'model', 'p/vendor/m${count - 1}'),
      ]);
      expect(t.takeException(), isNull);
    });

    testWidgets('desktop keeps a bounded dialog', (t) async {
      final api = _api(count: 200);
      await _open(t, api, thread: 'ses-a');
      await _openChip(t, 'model');
      final dialog = t.getRect(find.byType(OptionPickerList));
      expect(dialog.width, lessThanOrEqualTo(520));
      expect(dialog.height, lessThanOrEqualTo(900 * 0.8 + 1));
    });
  });

  group('visible model label', () {
    // Real metrics: the app's bundled prose face (read from the test asset
    // bundle, no download) under the app theme, as the chip renders it.
    setUpAll(() async {
      await loadPreviewFonts(always: true);
    });

    const longLabel = 'Some Very Long Provider Name/claude-sonnet-4-5';

    String shownIn(WidgetTester t, Finder scope) => t
        .widget<Text>(
          find.descendant(
            of: find.descendant(
              of: scope,
              matching: find.byType(TailEllipsisText),
            ),
            matching: find.byType(Text),
          ),
        )
        .data!;

    for (final size in [const Size(320, 640), const Size(1400, 900)]) {
      testWidgets('the model chip at ${size.width.toInt()} wide keeps the '
          'model readable', (t) async {
        final api = _api();
        api.sessionSettings['$_acp|ses-a'] = const SessionSettings(
          configOptions: [
            SessionConfigOption(
              id: 'model',
              name: 'Model',
              category: 'model',
              currentValue: 'p/long',
              values: [
                SessionConfigValue(value: 'p/long', name: longLabel),
                SessionConfigValue(value: 'p/short', name: 'Short'),
              ],
            ),
          ],
        );
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await api.appConnect(_acp, 28080);
        await t.pumpWidget(
          ProviderScope(
            overrides: [bridgeApiProvider.overrideWithValue(api)],
            child: MaterialApp(
              locale: const Locale('en'),
              theme: lightTheme(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const AppSessionScreen(serviceKey: _acp, threadId: 'ses-a'),
            ),
          ),
        );
        await _frames(t);
        final chip = find.byKey(const Key('agent-config-model'));
        await t.ensureVisible(chip);
        await _frames(t);
        final shown = shownIn(t, chip);
        expect(
          shown == longLabel ||
              (shown.startsWith('…') && longLabel.endsWith(shown.substring(1))),
          isTrue,
          reason: '"$shown" is the label or its end',
        );
        // Some of the label is visible, not just the ellipsis; how much of
        // its end fits depends on the width the options viewport leaves.
        expect(
          shown.replaceFirst('…', '').trim(),
          isNotEmpty,
          reason: '"$shown" shows part of the label',
        );
        // The chip never grows past the options viewport that clips it.
        final viewport = t.getRect(
          find.byKey(const Key('agent-session-options')),
        );
        final rect = t.getRect(chip);
        expect(
          rect.left >= viewport.left - 0.5 &&
              rect.right <= viewport.right + 0.5,
          isTrue,
          reason: 'chip $rect inside $viewport',
        );
        // The whole label stays available to assistive technology and on
        // hover.
        expect(find.bySemanticsLabel('Model: $longLabel'), findsOneWidget);
        final tooltip = t.widget<Tooltip>(
          find.descendant(of: chip, matching: find.byType(Tooltip)),
        );
        expect(tooltip.message, startsWith('Model: $longLabel'));
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('a narrow label drops its start, never its end', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: lightTheme(),
          home: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                // The chip's own text style.
                child: TailEllipsisText(
                  longLabel,
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
            ),
          ),
        ),
      );
      final shown = shownIn(t, find.byType(Scaffold));
      expect(shown, startsWith('…'));
      expect(shown, endsWith('sonnet-4-5'));
      expect(t.getSize(find.byType(TailEllipsisText)).width, 120);
    });

    testWidgets('a short label is shown whole', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: lightTheme(),
          home: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: TailEllipsisText(
                  'a/b',
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
            ),
          ),
        ),
      );
      expect(shownIn(t, find.byType(Scaffold)), 'a/b');
    });
  });

  group('prepared session', () {
    testWidgets('an opening finishing after the host dropped is not adopted', (
      t,
    ) async {
      final api = _api()..newSessionSettings = _settings();
      final gate = Completer<void>();
      api.threadStartGate = gate;
      await _open(t, api, cwd: '/work/alpha');
      await t.enterText(find.byKey(const Key('composer-input')), 'draft');
      await t.pump();
      api.pushEvent(
        _acp,
        const AppEvent(kind: 'acp/host/state', raw: '{"connected":false}'),
      );
      await t.pump();
      gate.complete();
      await t.pump();
      // Invocation order stays stable even if a fresh opening finishes too.
      final dropped = api.threadStartResults.first;
      expect(dropped, isNotNull);
      await _frames(t);
      expect(api.turnStartCount, 0);
      expect(api.sessionConfigCalls, isEmpty);
      expect(find.text('draft'), findsOneWidget);
      // Once the view is back, its message never goes to that session.
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      await _frames(t);
      await t.tap(find.byKey(const Key('send-btn')));
      await _frames(t);
      expect(api.lastTurnThread, isNot(dropped));
    });

    testWidgets('an opening finishing after the host generation changed is '
        'not adopted; the view opens a fresh one', (t) async {
      final api = _api()..newSessionSettings = _settings();
      final gate = Completer<void>();
      api.threadStartGate = gate;
      await _open(t, api, cwd: '/work/alpha');
      expect(find.byKey(const Key('agent-session-opening')), findsOneWidget);
      api.pushEvent(
        _acp,
        const AppEvent(
          kind: 'acp/host/state',
          raw: '{"generation":2,"connected":true}',
        ),
      );
      await t.pump();
      gate.complete();
      await t.pump();
      final stale = api.threadStartResults.first;
      expect(stale, isNotNull);
      await _frames(t);
      // The answering host opened a session of its own for the draft.
      expect(api.threadStartCalls, hasLength(2));
      expect(api.turnStartCount, 0);
      expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
      await _openChip(t, 'model');
      await _choose(t, 'p/vendor/m1');
      expect(api.sessionConfigCalls.single.$1, isNot(stale));
      await t.enterText(find.byKey(const Key('composer-input')), 'go');
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await _frames(t);
      expect(api.threadStartCalls, hasLength(2));
      expect(api.lastTurnThread, api.sessionConfigCalls.single.$1);
    });

    testWidgets(
      'an opened session keeps staged attachments and sends nothing',
      (t) async {
        final selector = FakeFileSelector();
        final previous = fsel.FileSelectorPlatform.instance;
        fsel.FileSelectorPlatform.instance = selector;
        addTearDown(() => fsel.FileSelectorPlatform.instance = previous);
        selector.files = [
          MemXFile(Uint8List.fromList(utf8.encode('x')), 'notes.txt'),
        ];
        final api = _api()..newSessionSettings = _settings();
        await _open(t, api, cwd: '/work/alpha');
        await attachMenu(t, 'attach-file-btn');
        await t.pumpAndSettle();
        expect(find.byKey(const Key('attachment-0')), findsOneWidget);
        await t.enterText(find.byKey(const Key('composer-input')), 'look');
        await t.pump();
        await _frames(t);
        expect(api.threadStartCalls, hasLength(1));
        expect(api.turnStartCount, 0);
        expect(find.byKey(const Key('attachment-0')), findsOneWidget);
        expect(find.text('notes.txt'), findsOneWidget);
        expect(find.text('look'), findsOneWidget);
        // The first send carries both, on the prepared session.
        await t.tap(find.byKey(const Key('send-btn')));
        await _frames(t);
        expect(api.threadStartCalls, hasLength(1));
        expect(api.lastTurnThread, api.appThreads.first.id);
        expect(api.lastTurnText, contains('look'));
        expect(api.lastTurnText, contains('notes.txt'));
      },
    );
  });

  testWidgets('Grok\'s Fast switches to its model\'s Fast variant and its '
      'permission mode reads in the app\'s words', (t) async {
    final api = _api();
    api.sessionSettings['$_acp|ses-a'] = const SessionSettings(
      configOptions: [
        SessionConfigOption(
          id: 'model',
          name: 'Model',
          category: 'model',
          currentValue: 'grok-4.7',
          values: [
            SessionConfigValue(value: 'grok-4.7', name: 'Grok 4.7'),
            SessionConfigValue(
              value: 'grok-4.7-build-fast',
              name: 'Grok 4.7 Fast',
            ),
            SessionConfigValue(value: 'grok-4.6', name: 'Grok 4.6'),
          ],
        ),
        SessionConfigOption(
          id: 'x.ai/permission_mode',
          name: 'Permissions',
          category: 'x.ai/permission',
          currentValue: 'ask',
          values: [
            SessionConfigValue(value: 'ask', name: 'Ask'),
            SessionConfigValue(value: 'auto', name: 'Auto'),
            SessionConfigValue(value: 'always-approve', name: 'Always approve'),
          ],
        ),
      ],
    );
    final shown = localizedSettings(
      api.sessionSettings['$_acp|ses-a']!,
      lookupAppLocalizations(const Locale('en')),
    ).configOptions.last;
    expect((shown.name, shown.currentLabel), ('Permission', 'Ask first'));
    await _open(t, api, thread: 'ses-a');
    await t.tap(find.byKey(const Key('agent-fast-btn')));
    await _frames(t);
    expect(api.sessionConfigCalls, [('ses-a', 'model', 'grok-4.7-build-fast')]);
    // A model without a Fast variant offers no Fast.
    expect(
      agentFastPair(
        const SessionSettings(
          configOptions: [
            SessionConfigOption(
              id: 'model',
              name: 'Model',
              category: 'model',
              currentValue: 'grok-4.6',
              values: [
                SessionConfigValue(value: 'grok-4.6', name: 'Grok 4.6'),
                SessionConfigValue(
                  value: 'grok-4.7-build-fast',
                  name: 'Grok 4.7 Fast',
                ),
              ],
            ),
          ],
        ),
      ),
      isNull,
    );
  });

  testWidgets('a short option list stays a menu under the limit', (t) async {
    expect(kOptionMenuLimit, 8);
    final api = _api(count: kOptionMenuLimit);
    await _open(t, api, thread: 'ses-a');
    await _openChip(t, 'model');
    expect(find.byKey(const Key('agent-option-search')), findsNothing);
    expect(find.byType(ChoiceRow<String>), findsNWidgets(kOptionMenuLimit));
  });
}
