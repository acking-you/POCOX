// Phone layouts that used to squeeze or overflow, measured with the real
// fonts on an iOS target at the narrowest width with the largest text:
// the services capability rows, the composer's agent options and model
// chip, the welcome guide's found host and the settings subscriptions. Set
// PCX_UI_PREVIEW_DIR to write the previews (`responsive-*`).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/screens/services_screen.dart';
import 'package:pocket_codex/src/screens/settings_screen.dart';
import 'package:pocket_codex/src/screens/welcome_guide_screen.dart';
import 'package:pocket_codex/src/theme.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/ui_preview.dart';
import 'package:pocket_codex/src/widgets/adaptive_sheet.dart';

const _device = 'ackingliu-mc1';
const _openCode = 'pcx:$_device:opencode:opencode';
const _codex = 'pcx:$_device:app:default';
const _cwd = '/work/pocket-codex';
// The narrowest phone at the largest text in both languages, and a common
// phone at default text: the cases where the layouts used to break.
const _cases = [
  (Size(320, 640), Locale('en'), 2.0),
  (Size(320, 640), Locale('zh'), 2.0),
  (Size(393, 852), Locale('en'), 1.0),
];
const _modelLabel = 'MiMo V2.6 Flash Free';

FakeBridgeApi _api() {
  final api = FakeBridgeApi(
    config: const ConfigInfo(relay: 'relay.example.com:7666', hasKey: true),
    services: const [
      ServiceEntry(
        device: _device,
        kind: 'opencode',
        name: 'opencode',
        key: _openCode,
      ),
      ServiceEntry(device: _device, kind: 'app', name: 'default', key: _codex),
    ],
  );
  api.acpCapabilities[_openCode] = negotiatedOpenCodeCapabilities();
  api.draftSettings['$_openCode|$_cwd'] = SessionSettings(
    configOptions: [
      SessionConfigOption(
        id: 'model',
        name: 'Model',
        category: 'model',
        currentValue: 'opencode/mimo',
        values: [
          const SessionConfigValue(value: 'opencode/mimo', name: _modelLabel),
          // Long enough a list to be searchable, as in the reported screen.
          for (var i = 0; i < 12; i++)
            SessionConfigValue(value: 'm$i', name: 'Model $i'),
        ],
      ),
      const SessionConfigOption(
        id: 'variant',
        name: 'Variant',
        category: 'thought_level',
        currentValue: '',
        values: [
          SessionConfigValue(value: '', name: 'Default'),
          SessionConfigValue(value: 'high', name: 'high'),
        ],
      ),
      const SessionConfigOption(
        id: 'agent',
        name: 'Agent',
        category: 'mode',
        currentValue: 'build',
        values: [
          SessionConfigValue(value: 'build', name: 'build'),
          SessionConfigValue(value: 'plan', name: 'plan'),
        ],
      ),
    ],
  );
  return api;
}

/// Mount [screen] on an iOS phone of [size].
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

/// Bounded pumps: connection probes and spinners never settle.
Future<void> _frames(WidgetTester t, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// [finder] lies wholly inside [bounds] and takes a tap.
void _reachable(WidgetTester t, Finder finder, Rect bounds, String why) {
  expect(finder.hitTestable(), findsOneWidget, reason: why);
  final rect = t.getRect(finder);
  expect(
    rect.left >= bounds.left - 0.5 &&
        rect.right <= bounds.right + 0.5 &&
        rect.top >= bounds.top - 0.5 &&
        rect.bottom <= bounds.bottom + 0.5,
    isTrue,
    reason: '$why: $rect outside $bounds',
  );
}

/// The [text] under [of] is shown whole: not ellipsized or cut.
void _whole(WidgetTester t, Finder of, String text, String why) {
  final found = find.descendant(of: of, matching: find.text(text));
  expect(found, findsOneWidget, reason: why);
  final paragraph = t.renderObject<RenderParagraph>(found);
  expect(paragraph.didExceedMaxLines, isFalse, reason: '$why: cut');
}

/// What the agent option [id]'s face reads.
String _face(WidgetTester t, String id) => t
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(Key('agent-config-$id')),
        matching: find.byType(Text),
      ),
    )
    .map((w) => w.data ?? '')
    .firstWhere((d) => d.isNotEmpty);

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

void main() {
  setUpAll(() => loadPreviewFonts(always: true));
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('capability rows keep the title, status and actions '
      'whole at every phone width, language and text size', (t) async {
    await _onIos(t, () async {
      final row = find.byKey(const Key('device-capability-$_openCode'));
      for (final (size, locale, scale) in _cases) {
        final l10n = lookupAppLocalizations(locale);
        final api = _api();
        await api.appConnect(_openCode, 1);
        await _mount(
          t,
          api,
          const ServicesScreen(),
          size: size,
          scale: scale,
          locale: locale,
        );
        await t.tap(find.byKey(const Key('device-$_device')));
        await _frames(t);
        final at = '$size ${locale.languageCode} ×$scale';
        expect(t.takeException(), isNull, reason: 'no overflow: $at');
        // Large text can push the row below the fold: scroll to it.
        await t.ensureVisible(row);
        await t.pump();
        final bounds = t.getRect(row);
        expect(
          bounds.bottom,
          lessThanOrEqualTo(size.height),
          reason: 'row on screen $at',
        );
        // The provider names the row; its kind rides the facts line.
        _whole(t, row, 'OpenCode', 'title $at');
        expect(
          find.descendant(
            of: row,
            matching: find.textContaining(l10n.servicesChatCapability),
          ),
          findsOneWidget,
          reason: 'kind $at',
        );
        _whole(t, row, l10n.statusConnected, 'status $at');
        _reachable(
          t,
          find.descendant(
            of: row,
            matching: find.widgetWithText(TextButton, l10n.servicesOpen),
          ),
          bounds,
          'open $at',
        );
        _reachable(
          t,
          find.descendant(
            of: row,
            matching: find.byType(PopupMenuButton<VoidCallback>),
          ),
          bounds,
          'more $at',
        );
        await capturePreview(
          t,
          'responsive-services-${size.width.toInt()}-'
          '${locale.languageCode}-$scale',
        );
      }

      // The overflow still opens its menu from the stacked row.
      await t.tap(
        find.descendant(
          of: row,
          matching: find.byType(PopupMenuButton<VoidCallback>),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byType(PopupMenuItem<VoidCallback>), findsWidgets);
      await t.tapAt(const Offset(5, 5));
      await t.pumpAndSettle();

      // A tablet keeps the status beside the title.
      final api = _api();
      await api.appConnect(_openCode, 1);
      await _mount(t, api, const ServicesScreen(), size: const Size(834, 1112));
      await t.tap(find.byKey(const Key('device-$_device')));
      await _frames(t);
      expect(t.takeException(), isNull);
      final l10n = lookupAppLocalizations(const Locale('en'));
      final title = t.getRect(
        find.descendant(of: row, matching: find.text('OpenCode')),
      );
      final status = t.getRect(
        find.descendant(of: row, matching: find.text(l10n.statusConnected)),
      );
      expect(status.left, greaterThan(title.right), reason: 'one line');
      expect(status.top, lessThan(title.bottom + 12), reason: 'one line');
    });
  });

  testWidgets('an agent\'s options get a line of their own on a phone; every '
      'one stays readable and opens, and nothing is sent', (t) async {
    await _onIos(t, () async {
      const screen = AppSessionScreen(
        serviceKey: _openCode,
        cwd: _cwd,
        home: true,
      );
      for (final (size, scale) in const [
        (Size(320, 640), 2.0),
        (Size(393, 852), 1.0),
      ]) {
        final api = _api();
        await api.appConnect(_openCode, 1);
        await _mount(t, api, screen, size: size, scale: scale);
        final at = '$size ×$scale';
        expect(t.takeException(), isNull, reason: 'no overflow: $at');
        final screenRect = Offset.zero & size;
        for (final id in ['model', 'variant', 'agent']) {
          _reachable(
            t,
            find.byKey(Key('agent-config-$id')),
            screenRect,
            '$id $at',
          );
        }
        // Above the attach and send row, not squeezed between them.
        final send = t.getRect(find.byKey(const Key('send-btn')));
        final model = t.getRect(find.byKey(const Key('agent-config-model')));
        expect(model.bottom, lessThanOrEqualTo(send.top), reason: at);
        // The model reads whole, or keeps at least half its tail.
        final face = _face(t, 'model');
        expect(
          face == _modelLabel ||
              face.startsWith('…') &&
                  _modelLabel.endsWith(face.substring(1)) &&
                  face.length > _modelLabel.length / 2,
          isTrue,
          reason: 'model reads "$face" at $at',
        );
        await capturePreview(
          t,
          'responsive-composer-options-${size.width.toInt()}-$scale',
        );
      }

      // A choice from the stacked line applies to the draft and sends nothing.
      final api = _api();
      await api.appConnect(_openCode, 1);
      await _mount(t, api, screen, size: const Size(393, 852));
      await t.tap(find.byKey(const Key('agent-config-variant')));
      await t.pumpAndSettle();
      await t.tap(
        find.byWidgetPredicate(
          (w) => w is ChoiceRow<String> && w.value == 'high',
        ),
      );
      await _frames(t);
      expect(_face(t, 'variant'), 'high');
      expect(api.turnStartCount, 0, reason: 'no automatic send');
      expect(api.threadStartCalls, isEmpty);

      // With the keyboard up on a small phone the options rejoin the
      // toolbar, so the conversation keeps its height. There they scroll
      // within the capsule: each one, revealed, lies whole above the
      // keyboard and takes a tap.
      t.view.physicalSize = const Size(320, 640);
      t.view.viewInsets = const FakeViewPadding(bottom: 280);
      await _frames(t);
      expect(t.takeException(), isNull);
      final open = Offset.zero & const Size(320, 360);
      _reachable(t, find.byKey(const Key('send-btn')), open, 'send');
      for (final id in ['agent', 'variant', 'model']) {
        final chip = find.byKey(Key('agent-config-$id'));
        await t.ensureVisible(chip);
        await t.pump();
        _reachable(t, chip, open, '$id above the keyboard');
      }
      expect(_face(t, 'variant'), 'high', reason: 'the choice survives');
      await capturePreview(t, 'responsive-composer-options-keyboard');

      // Landscape: one toolbar line, everything reachable.
      t.view.viewInsets = FakeViewPadding.zero;
      t.view.physicalSize = const Size(852, 393);
      await _frames(t);
      expect(t.takeException(), isNull);
      for (final key in [
        'agent-config-model',
        'agent-config-agent',
        'send-btn',
      ]) {
        _reachable(
          t,
          find.byKey(Key(key)),
          Offset.zero & const Size(852, 393),
          '$key landscape',
        );
      }
      await capturePreview(t, 'responsive-composer-options-landscape');
    });
  });

  testWidgets('the Codex model chip keeps its label on a phone', (t) async {
    await _onIos(t, () async {
      const screen = AppSessionScreen(serviceKey: _codex, home: true);
      for (final (size, locale, scale) in _cases) {
        final l10n = lookupAppLocalizations(locale);
        final api = _api();
        await api.appConnect(_codex, 1);
        await _mount(t, api, screen, size: size, scale: scale, locale: locale);
        final at = '$size ${locale.languageCode} ×$scale';
        expect(t.takeException(), isNull, reason: 'no overflow: $at');
        final chip = find.byKey(const Key('model-chip'));
        _reachable(t, chip, Offset.zero & size, 'model $at');
        _whole(t, chip, l10n.modelDefault, 'model label $at');
        // The permission label stays readable too: beside attach or, at
        // 320 px with large text, on the line above with the model.
        final permission = find.byKey(const Key('permission-chip'));
        _reachable(t, permission, Offset.zero & size, 'permission $at');
        _whole(t, permission, l10n.modeAuto, 'permission label $at');
        _reachable(
          t,
          find.byKey(const Key('send-btn')),
          Offset.zero & size,
          'send $at',
        );
        await capturePreview(
          t,
          'responsive-codex-composer-${size.width.toInt()}-'
          '${locale.languageCode}-$scale',
        );
      }
      // Its sheet still opens from the line above the toolbar.
      await t.tap(find.byKey(const Key('model-chip')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('opt-model')), findsOneWidget);
      await t.tapAt(const Offset(5, 5));
      await t.pumpAndSettle();

      // With the keyboard up on a small phone both chips rejoin the toolbar
      // (the conversation keeps its height) and stay tappable entries.
      t.view.physicalSize = const Size(320, 640);
      t.view.viewInsets = const FakeViewPadding(bottom: 280);
      await _frames(t);
      expect(t.takeException(), isNull);
      final open = Offset.zero & const Size(320, 360);
      for (final key in ['permission-chip', 'model-chip', 'send-btn']) {
        _reachable(t, find.byKey(Key(key)), open, '$key above the keyboard');
      }
      final send = t.getRect(find.byKey(const Key('send-btn')));
      expect(
        t.getRect(find.byKey(const Key('permission-chip'))).center.dy,
        closeTo(send.center.dy, 1),
        reason: 'one toolbar line',
      );
    });
  });

  testWidgets('a new conversation sits above the composer on a phone, its '
      'other projects in one row', (t) async {
    await _onIos(t, () async {
      const screen = AppSessionScreen(
        serviceKey: _codex,
        home: true,
        cwd: _cwd,
      );
      for (final (size, locale, scale) in _cases) {
        final api = _api()
          ..appThreads.addAll([
            for (final (i, cwd) in [
              _cwd,
              '/w/alpha',
              '/w/beta',
              '/w/gamma',
            ].indexed)
              ThreadMeta(id: 't$i', preview: 'p$i', cwd: cwd, updatedAt: i),
          ]);
        await api.appConnect(_codex, 1);
        await _mount(t, api, screen, size: size, scale: scale, locale: locale);
        final at = '$size ${locale.languageCode} ×$scale';
        expect(t.takeException(), isNull, reason: 'no overflow: $at');
        // Nothing of the view lies under the composer's glass.
        final composerTop = t
            .getRect(find.byKey(const Key('composer-input')))
            .top;
        final above = Offset.zero & Size(size.width, composerTop);
        _reachable(
          t,
          find.byKey(const Key('project-switcher-btn')),
          above,
          'project $at',
        );
        final row = find.byKey(const Key('agent-welcome-recent-row'));
        final alpha = find.byKey(const Key('agent-welcome-recent-/w/alpha'));
        // At default text the row waits just above the composer; with the
        // largest text the view scrolls to it as one column.
        if (scale == 1) {
          expect(
            t.getRect(row).bottom,
            lessThanOrEqualTo(composerTop),
            reason: 'projects row $at',
          );
        } else {
          await t.ensureVisible(alpha);
          await _frames(t, 3);
        }
        _reachable(t, alpha, above, 'recent project $at');
        // One row that swipes, however many projects, ending with the
        // folder chooser.
        expect(
          t.getRect(find.byKey(const Key('agent-welcome-recent-/w/gamma'))).top,
          t.getRect(alpha).top,
          reason: 'one row $at',
        );
        expect(
          find.descendant(
            of: row,
            matching: find.byKey(const Key('agent-welcome-choose-folder')),
          ),
          findsOneWidget,
        );
        await capturePreview(
          t,
          'responsive-new-conversation-${size.width.toInt()}-'
          '${locale.languageCode}-$scale',
        );
      }
    });
  });

  testWidgets('a found host with a long name wraps inside its step', (t) async {
    await _onIos(t, () async {
      for (final locale in const [Locale('en'), Locale('zh')]) {
        final l10n = lookupAppLocalizations(locale);
        await _mount(
          t,
          _api(),
          const WelcomeGuideScreen(),
          size: const Size(320, 640),
          scale: 2,
          locale: locale,
        );
        final at = locale.languageCode;
        expect(t.takeException(), isNull, reason: 'no overflow: $at');
        final label = find.text(l10n.welcomeHostFound('$_device · opencode'));
        // The steps are a lazy list: scroll the third one in.
        await t.scrollUntilVisible(label, 100);
        await t.pump();
        final rect = t.getRect(label);
        expect(rect.right, lessThanOrEqualTo(320), reason: at);
        expect(
          t.renderObject<RenderParagraph>(label).didExceedMaxLines,
          isFalse,
          reason: at,
        );
        await capturePreview(t, 'responsive-welcome-320-$at-2.0');
      }
    });
  });

  testWidgets('subscriptions are listed by their service key, not the '
      'internal identity', (t) async {
    await _onIos(t, () async {
      final api = _api();
      await api.apiSubscribe(
        'opencode\u001fself:relay.example.com:7666#0eb093e3\u001f$_openCode',
        64001,
      );
      await _mount(
        t,
        api,
        const SettingsScreen(),
        size: const Size(393, 852),
        locale: const Locale('zh'),
      );
      final key = find.text(_openCode);
      await t.scrollUntilVisible(key, 200);
      await t.pump();
      expect(key, findsOneWidget);
      expect(find.textContaining('\u001f'), findsNothing);
      expect(find.textContaining('#0eb093e3'), findsNothing);
      expect(find.text('127.0.0.1:64001'), findsOneWidget);
      await capturePreview(t, 'responsive-settings-subscriptions');
    });
  });

  testWidgets('a pending approval and the composer stay reachable with '
      'large text, landscape and the keyboard', (t) async {
    await _onIos(t, () async {
      const screen = AppSessionScreen(
        serviceKey: _codex,
        threadId: 't1',
        home: true,
      );
      const command =
          'cargo test -p pocket_codex_bridge --locked -- serve_lifecycle '
          '/Users/me/work/pocket-codex/crates/pocket-codex-bridge/src';
      FakeBridgeApi? last;
      const scale = 2.0;
      for (final (size, keyboard) in const [
        (Size(320, 640), 280.0),
        (Size(393, 852), 336.0),
        (Size(852, 393), 190.0),
      ]) {
        final api = last = _api()
          ..readResult = const ThreadHistory(
            items: [
              ThreadItem(
                id: 'u1',
                itemType: 'userMessage',
                title: '',
                text: '运行测试并解释失败原因',
              ),
              ThreadItem(
                id: 'a1',
                itemType: 'agentMessage',
                title: '',
                text: '我需要先运行测试。',
              ),
            ],
            running: false,
          );
        await api.appConnect(_codex, 1);
        t.view.viewInsets = FakeViewPadding.zero;
        await _mount(
          t,
          api,
          screen,
          size: size,
          scale: scale,
          locale: const Locale('zh'),
        );
        api.pushEvent(
          _codex,
          const AppEvent(
            kind: 'execCommandApproval',
            requestId: '7',
            raw: '{"command":"$command","cwd":"/Users/me/work/pocket-codex"}',
          ),
        );
        await _frames(t);
        await t.enterText(find.byKey(const Key('composer-input')), '草稿');
        t.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await _frames(t);
        final at = '$size kb=$keyboard ×$scale';
        expect(t.takeException(), isNull, reason: 'no overflow: $at');
        final open = Offset.zero & Size(size.width, size.height - keyboard);
        for (final key in ['approve-btn', 'composer-input', 'send-btn']) {
          final control = find.byKey(Key(key));
          await t.ensureVisible(control);
          await t.pump();
          _reachable(t, control, open, '$key $at');
        }
        expect(
          t
              .widget<TextField>(find.byKey(const Key('composer-input')))
              .controller!
              .text,
          '草稿',
          reason: 'the draft survives the keyboard: $at',
        );
        await capturePreview(
          t,
          'responsive-approval-${size.width.toInt()}x'
          '${size.height.toInt()}-kb${keyboard.toInt()}-2.0',
        );
      }
      // Still answerable from there, and nothing is sent.
      await t.ensureVisible(find.byKey(const Key('approve-btn')));
      await t.pump();
      await t.tap(find.byKey(const Key('approve-btn')));
      await _frames(t);
      expect(last!.lastApprovalDecision, 'accept');
      expect(last.turnStartCount, 0);
      t.view.viewInsets = FakeViewPadding.zero;
    });
  });

  testWidgets('the host switcher sheet keeps device names recognisable', (
    t,
  ) async {
    await _onIos(t, () async {
      const size = Size(320, 640);
      const scale = 2.0;
      final api = _api();
      api.services.add(
        const ServiceEntry(
          device: 'studio-mini',
          kind: 'app',
          name: 'default',
          key: 'pcx:studio-mini:app:default',
        ),
      );
      await api.appConnect(_codex, 1);
      await _mount(
        t,
        api,
        AppSessionScreen(
          serviceKey: _codex,
          home: true,
          services: api.services,
        ),
        size: size,
        scale: scale,
        locale: const Locale('zh'),
      );
      await t.tap(find.byKey(const Key('sidebar-open-btn')));
      await _frames(t);
      await t.tap(find.byKey(const Key('sidebar-service-switcher')));
      await _frames(t);
      final at = '$size ×$scale';
      expect(t.takeException(), isNull, reason: 'no overflow: $at');
      for (final s in api.services) {
        final item = find.byKey(Key('host-switch-item-${s.key}'));
        await t.ensureVisible(item);
        await t.pump();
        _reachable(t, item, Offset.zero & size, '${s.key} $at');
        final device = find.descendant(of: item, matching: find.text(s.device));
        expect(
          t.renderObject<RenderParagraph>(device).didExceedMaxLines,
          isFalse,
          reason: '${s.device} whole at $at',
        );
      }
      await capturePreview(t, 'responsive-host-switcher-320-zh-2.0');
    });
  });

  testWidgets('the phone sidebar keeps every row in landscape; its heading '
      'controls are touch-sized', (t) async {
    await _onIos(t, () async {
      const screen = AppSessionScreen(serviceKey: _codex, home: true);
      for (final size in const [Size(852, 393), Size(393, 852)]) {
        const scale = 2.0;
        final api = _api();
        await api.appConnect(_codex, 1);
        await _mount(
          t,
          api,
          screen,
          size: size,
          scale: scale,
          locale: const Locale('zh'),
        );
        final menu = find.byKey(const Key('sidebar-open-btn'));
        if (menu.evaluate().isNotEmpty) {
          await t.tap(menu);
          await _frames(t);
        }
        final at = '$size ×$scale';
        expect(t.takeException(), isNull, reason: 'no overflow: $at');
        for (final key in [
          'new-conversation-btn',
          'activity-view-btn',
          'sidebar-settings-btn',
        ]) {
          final control = find.byKey(Key(key));
          // Portrait keeps the footer pinned: no scrolling needed there.
          if (size.width > size.height) await t.ensureVisible(control);
          await t.pump();
          _reachable(t, control, Offset.zero & size, '$key $at');
        }
        final heading = t.getSize(find.byKey(const Key('activity-view-btn')));
        expect(heading.height, greaterThanOrEqualTo(44), reason: at);
        if (size.width > size.height) {
          await capturePreview(t, 'responsive-sidebar-landscape-zh-2.0');
        }
      }
    });
  });
}
