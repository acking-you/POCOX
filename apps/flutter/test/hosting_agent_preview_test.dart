// The hosting and agent-control scenes on a 320 and a 390 phone, an 800
// tablet and a 1440 desktop, light and dark, English and Chinese, with the
// app's real themes: the new-host dialog (Codex beside a running host; the
// chooser scrolled to the saved and custom agents and their forms; the
// an ACP preset beside a saved configuration of the same name, also under 3×
// text; the preset unfolded down to its program, arguments and Start;
// native OpenCode beside them), the
// manage page with Codex and an ACP agent hosted, the ACP composer chips
// (each brought on screen), and the model list searched with a phone
// keyboard up. Each captured control is checked on screen and operable.
//
// Set POCOX_UI_PREVIEW_DIR to also write each scene as a PNG for review
// (fonts as in acp_layout_test; nothing is downloaded).

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/screens/app_session_screen.dart';
import 'package:pocox/src/screens/services_screen.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/ui_prefs.dart';
import 'package:pocox/src/widgets/group_card.dart';
import 'package:pocox/src/widgets/local_host_dialog.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/agent_catalog_fixture.dart';
import 'support/ui_preview.dart';

part 'hosting_preview/layout_assertions.dart';

const _acp = 'pcx:dev:acp:agent';

const _devices = [
  ('phone320', Size(320, 640)),
  ('phone390', Size(390, 844)),
  ('tablet800', Size(800, 1100)),
  ('desktop1440', Size(1440, 900)),
];

final _caps = negotiatedAcpCapabilities(
  providerName: 'Fixture Agent',
  profileId: 'fixture',
);

const _savedAgent = AcpAgentSpec(
  profileId: 'custom-audit',
  displayName: 'Internal Enterprise Security & Code Audit Agent',
  program: '/opt/agents/audit-runner',
  args: ['--audit'],
);

/// A saved configuration with the fixture preset's own id and name.
const _savedFixture = AcpAgentSpec(
  profileId: 'fixture',
  displayName: 'Fixture Agent',
  program: '/opt/fx/bin/fixture-agent',
  args: ['acp', '--port', '4100'],
);

/// The chooser with a saved configuration named like the fixture preset:
/// each section revealed in turn, its heading and tile whole on screen, the
/// tile's source in its tooltip and label; frames are `$name-presets` and
/// `$name-saved`.
Future<void> _captureSameName(
  WidgetTester t,
  Size size,
  Locale locale,
  String name, {
  bool large = false,
}) async {
  final l10n = lookupAppLocalizations(locale);
  final sections = [
    (
      'presets',
      'agent-choice-builtin',
      l10n.agentChoiceBuiltinTitle,
      'agent-choice-preset:fixture',
      l10n.agentChoicePreset,
    ),
    (
      'saved',
      'agent-choice-mine',
      l10n.agentChoiceSavedTitle,
      'agent-choice-saved:fixture',
      l10n.agentChoiceSaved,
    ),
  ];
  for (final (frame, section, heading, tile, source) in sections) {
    // Scroll the section's top edge to the top of the dialog's scroll view
    // (as far as it can scroll); the preset's tile is then checked within it.
    final group = find.byKey(Key(section));
    await _reveal(t, group);
    final shownTile = find.byKey(Key(tile));
    final view = t.getRect(
      find.ancestor(of: group, matching: find.byType(Scrollable)).first,
    );
    // Under large text the heading and the tile may not fit together: the
    // tile, whose tooltip and label name its source too, then ends the view.
    final together = t.getRect(shownTile).bottom <= view.bottom + 0.5;
    if (!large) {
      expect(together, isTrue, reason: 'heading and tile together ($frame)');
    }
    if (!together) {
      await Scrollable.ensureVisible(t.element(shownTile), alignment: 1);
      await t.pumpAndSettle();
    }
    expect(t.takeException(), isNull, reason: 'no overflow ($frame)');
    _usable(t, shownTile, size);
    for (final text in [
      if (together) find.descendant(of: group, matching: find.text(heading)),
      find.descendant(of: shownTile, matching: find.text('Fixture Agent')),
    ]) {
      expect(text, findsOneWidget, reason: '$text');
      final rect = t.getRect(text);
      expect(
        rect.top >= view.top - 0.5 && rect.bottom <= view.bottom + 0.5,
        isTrue,
        reason: '$text $rect inside the scroll view $view ($frame)',
      );
      expect(
        t.renderObject<RenderParagraph>(text).didExceedMaxLines,
        isFalse,
        reason: '$text is whole',
      );
    }
    expect(
      find.bySemanticsLabel('Fixture Agent, $source'),
      findsOneWidget,
      reason: 'one node names the tile and its source',
    );
    expect(
      t
          .widget<Tooltip>(
            find.ancestor(of: shownTile, matching: find.byType(Tooltip)).first,
          )
          .message,
      source,
      reason: 'the tile names its source on hover',
    );
    await capturePreview(t, '$name-$frame');
  }
}

class _PreviewPrefs extends UiPrefsStore {
  _PreviewPrefs(this._prefs);
  final UiPrefs _prefs;
  @override
  Future<UiPrefs> load() async => _prefs;
  @override
  Future<void> save(UiPrefs prefs) async {}
}

Widget _app(
  Widget home,
  BridgeApi api,
  Locale locale,
  Brightness brightness, {
  UiPrefs? prefs,
}) => ProviderScope(
  overrides: [
    bridgeApiProvider.overrideWithValue(api),
    if (prefs != null) uiPrefsProvider.overrideWith(() => _PreviewPrefs(prefs)),
  ],
  child: MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: brightness == Brightness.light ? lightTheme() : darkTheme(),
    builder: (context, child) => RepaintBoundary(key: previewKey, child: child),
    home: home,
  ),
);

void _size(WidgetTester t, Size size) {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  addTearDown(t.view.resetViewInsets);
}

/// Bounded frames: session screens animate while connected.
Future<void> _frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Nothing laid out past the left or right edge of the screen.
void _withinWidth(WidgetTester t, Finder finder, Size size) {
  expect(finder, findsWidgets);
  for (final element in finder.evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    expect(rect.left, greaterThanOrEqualTo(-0.5), reason: '$finder starts');
    expect(rect.right, lessThanOrEqualTo(size.width + 0.5), reason: '$finder');
  }
}

/// The title bar's "Host this device" action is usable in one of its two
/// valid forms and returns which: the labelled button, whose label's natural
/// line (not just its constrained box) fits inside the button, or the icon
/// button named by its tooltip. Either way it is an enabled button that can
/// be tapped and focused, announced with the full [text].
bool _primaryActionShown(WidgetTester t, Size size, String text) {
  final action = find.byKey(const Key('host-this-device-btn'));
  _usable(t, action, size);
  final handle = t.ensureSemantics();
  try {
    final label = find.descendant(of: action, matching: find.text(text));
    final labelled = label.evaluate().isNotEmpty;
    expect(
      t.getSemantics(action),
      isSemantics(
        label: labelled ? text : null,
        tooltip: labelled ? null : text,
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    if (!labelled) {
      expect(find.byTooltip(text), findsOneWidget);
      return false;
    }
    // A paragraph squeezed into a shorter box still reports a whole line
    // (didExceedMaxLines is false) while its glyphs are cut at the box's
    // edge, so compare the line's natural height with what it was given.
    final paragraph = t.renderObject<RenderParagraph>(label);
    final natural = TextPainter(
      text: paragraph.text,
      textDirection: paragraph.textDirection,
      textScaler: paragraph.textScaler,
      maxLines: 1,
    )..layout();
    expect(
      natural.height,
      lessThanOrEqualTo(paragraph.size.height + 0.5),
      reason: '"$text" needs ${natural.height}, has ${paragraph.size.height}',
    );
    expect(
      natural.width,
      lessThanOrEqualTo(paragraph.size.width + 0.5),
      reason: '"$text" is whole across',
    );
    natural.dispose();
    final button = t.getRect(action);
    final box = t.getRect(label);
    expect(
      box.top >= button.top - 0.5 && box.bottom <= button.bottom + 0.5,
      isTrue,
      reason: 'label $box inside the button $button',
    );
    return true;
  } finally {
    handle.dispose();
  }
}

Future<FakeBridgeApi> _hostedApi() async {
  final api = FakeBridgeApi(
    config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
  );
  api.presets = const [
    fixturePreset,
    AcpPreset(
      id: 'claude',
      displayName: 'Claude',
      program: 'claude-agent-acp',
      args: [],
    ),
  ];
  await api.appServeStart(port: 18080, name: 'default', embedded: false);
  await api.appServeStartAcp(
    name: 'fixture',
    spec: const AcpAgentSpec(
      profileId: 'fixture',
      displayName: 'Fixture Agent',
      program: 'fixture-agent',
      args: ['acp'],
    ),
  );
  return api;
}

Future<void> _openDialog(
  WidgetTester t,
  FakeBridgeApi api,
  Locale locale,
  Brightness brightness, {
  List<AcpAgentSpec> saved = const [_savedAgent],
}) async {
  await t.pumpWidget(
    _app(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showHostingEditor(context),
            child: const Text('open'),
          ),
        ),
      ),
      api,
      locale,
      brightness,
      prefs: UiPrefs(acpAgents: saved),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

Future<void> _openSession(
  WidgetTester t,
  FakeBridgeApi api,
  Locale locale,
  Brightness brightness, {
  SessionSettings? settings,
}) async {
  api
    ..acpCapabilities[_acp] = _caps
    ..sessionSettings['$_acp|ses-1'] = settings ?? previewAgentSettings();
  await api.appConnect(_acp, 28080);
  await t.pumpWidget(
    _app(
      const AppSessionScreen(serviceKey: _acp, threadId: 'ses-1'),
      api,
      locale,
      brightness,
    ),
  );
  await _frames(t);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The same-name scenes measure real titles and wrapping, so this file
  // always renders with the app's fonts (Ahem would misreport them).
  setUpAll(() => loadPreviewFonts(always: true));
  setUp(AppSessionScreen.debugResetThreadMemory);

  for (final (device, size) in _devices) {
    for (final brightness in Brightness.values) {
      for (final language in ['en', 'zh']) {
        final locale = Locale(language);
        final variant = '$device-${brightness.name}-$language';

        testWidgets('new-host dialog beside a running host ($variant)', (
          t,
        ) async {
          _size(t, size);
          final api = await _hostedApi();
          await _openDialog(t, api, locale, brightness);
          expect(t.takeException(), isNull, reason: 'no overflow');
          _withinWidth(t, find.byKey(const Key('agent-choice-grid')), size);
          expect(
            find.byKey(const Key('agent-choice-preset:claude')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('agent-icon-claude')), findsOneWidget);
          expect(
            find.byKey(const Key('agent-choice-saved:custom-audit')),
            findsOneWidget,
          );
          final name = t.widget<TextField>(
            find.byKey(const Key('codex-name-field')),
          );
          expect(name.controller!.text, 'default-2');
          // Each Codex source choice reads as one line.
          final l10n = lookupAppLocalizations(locale);
          _oneLine(t, find.text(l10n.codexSourceExternal));
          _oneLine(
            t,
            find.text(
              '${l10n.codexSourceBuiltin} · ${l10n.codexBuiltinUnavailable}',
            ),
          );
          await capturePreview(t, 'hosting-dialog-$variant');
          final start = find.byKey(const Key('start-hosting-btn'));
          await t.ensureVisible(start);
          await t.pumpAndSettle();
          _withinWidth(t, start, size);
          _operable(t, start);
        });

        testWidgets('chooser scrolled to the saved and custom agents, and '
            'their forms ($variant)', (t) async {
          _size(t, size);
          final api = await _hostedApi();
          await _openDialog(t, api, locale, brightness);
          // The full production chooser.
          for (final choice in [
            'codex',
            'opencode',
            'preset:fixture',
            'preset:claude',
            'saved:custom-audit',
            'custom',
          ]) {
            expect(find.byKey(Key('agent-choice-$choice')), findsOneWidget);
          }
          final saved = find.byKey(
            const Key('agent-choice-saved:custom-audit'),
          );
          final custom = find.byKey(const Key('agent-choice-custom'));
          await _reveal(t, custom);
          await _reveal(t, saved);
          expect(t.takeException(), isNull, reason: 'no overflow');
          _usable(t, saved, size);
          expect(
            find.bySemanticsLabel(
              RegExp('^${RegExp.escape(_savedAgent.displayName)}, '),
            ),
            findsOneWidget,
          );
          await capturePreview(t, 'hosting-chooser-saved-$variant');

          // The saved agent's form: its long name, editable.
          await t.tap(saved);
          await t.pumpAndSettle();
          final display = find.byKey(const Key('acp-display-name-field'));
          await _reveal(t, display);
          expect(t.takeException(), isNull, reason: 'no overflow');
          expect(
            t.widget<TextField>(display).controller!.text,
            _savedAgent.displayName,
          );
          _usable(t, display, size);
          _usable(t, find.byKey(const Key('acp-instance-name-field')), size);
          _usable(t, find.byKey(const Key('start-hosting-btn')), size);
          await capturePreview(t, 'hosting-saved-form-$variant');

          final advanced = find.descendant(
            of: find.byKey(const Key('acp-advanced-toggle')),
            matching: find.byType(TextButton),
          );
          await _reveal(t, advanced);
          await t.tap(advanced);
          await t.pumpAndSettle();
          await _captureProgram(
            t,
            size,
            'hosting-saved-program-$variant',
            program: _savedAgent.program,
            firstArg: _savedAgent.args.first,
            l10n: lookupAppLocalizations(locale),
          );

          // A new custom agent: empty fields, the save choice and Start.
          await _reveal(t, custom);
          await t.tap(custom);
          await t.pumpAndSettle();
          final save = find.byKey(const Key('acp-save-agent'));
          await _reveal(t, save);
          expect(t.takeException(), isNull, reason: 'no overflow');
          _usable(t, save, size);
          _usable(t, find.byKey(const Key('start-hosting-btn')), size);
          expect(
            t
                .widget<TextField>(find.byKey(const Key('acp-program-field')))
                .controller!
                .text,
            isEmpty,
          );
          await capturePreview(t, 'hosting-custom-save-$variant');
        });

        testWidgets('an ACP preset beside a same-name saved configuration '
            '($variant)', (t) async {
          _size(t, size);
          final api = await _hostedApi();
          await _openDialog(
            t,
            api,
            locale,
            brightness,
            saved: const [_savedFixture, _savedAgent],
          );
          await _captureSameName(t, size, locale, 'hosting-same-name-$variant');
        });

        testWidgets('an ACP preset unfolded ($variant)', (t) async {
          _size(t, size);
          final api = await _hostedApi();
          await _openDialog(t, api, locale, brightness);
          final tile = find.byKey(const Key('agent-choice-preset:fixture'));
          await t.ensureVisible(tile);
          await t.tap(tile);
          await t.pump(const Duration(milliseconds: 400));
          await t.pumpAndSettle();
          final advanced = find.descendant(
            of: find.byKey(const Key('acp-advanced-toggle')),
            matching: find.byType(TextButton),
          );
          await t.ensureVisible(advanced);
          await t.pumpAndSettle();
          await t.tap(advanced);
          await t.pumpAndSettle();
          expect(find.byKey(const Key('acp-arg-field-0')), findsOneWidget);
          expect(t.takeException(), isNull, reason: 'no overflow');
          _withinWidth(t, find.byKey(const Key('acp-host-form')), size);
          await capturePreview(t, 'hosting-acp-preset-$variant');
          await _captureProgram(
            t,
            size,
            'hosting-acp-preset-program-$variant',
            program: 'fixture-agent',
            firstArg: 'acp',
            l10n: lookupAppLocalizations(locale),
            short: true,
          );
        });

        testWidgets('native OpenCode chosen ($variant)', (t) async {
          _size(t, size);
          final api = await _hostedApi();
          await _openDialog(t, api, locale, brightness);
          final tile = find.byKey(const Key('agent-choice-opencode'));
          await t.ensureVisible(tile);
          await t.tap(tile);
          await t.pumpAndSettle();
          final section = find.byKey(const Key('opencode-runtime-section'));
          await _reveal(t, section);
          expect(t.takeException(), isNull, reason: 'no overflow');
          _withinWidth(t, section, size);
          _usable(t, find.byKey(const Key('opencode-name-field')), size);
          final start = find.byKey(const Key('start-hosting-btn'));
          await t.ensureVisible(start);
          await t.pumpAndSettle();
          _operable(t, start);
          await capturePreview(t, 'hosting-opencode-native-$variant');
        });

        testWidgets('manage page with Codex and an ACP agent ($variant)', (
          t,
        ) async {
          _size(t, size);
          // Hosting is desktop-only; Linux keeps the bundled prose face.
          debugDefaultTargetPlatformOverride = TargetPlatform.linux;
          try {
            final api = await _hostedApi();
            await t.pumpWidget(
              _app(const ServicesScreen(), api, locale, brightness),
            );
            await t.pumpAndSettle();
            expect(t.takeException(), isNull, reason: 'no overflow');
            // Labelled where it fits, else named by its tooltip; the way
            // back to the chat stays on the bar either way.
            final labelled = _primaryActionShown(
              t,
              size,
              lookupAppLocalizations(locale).servicesHostThisDevice,
            );
            if (size.width >= 1440) {
              expect(labelled, isTrue, reason: 'a desktop bar has room');
            }
            _operable(t, find.byKey(const Key('utility-chat-origin')));
            await capturePreview(t, 'hosting-manage-$variant');
            await t.pumpWidget(const SizedBox());
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });

        testWidgets('agent chips ($variant)', (t) async {
          _size(t, size);
          final api = FakeBridgeApi();
          await _openSession(t, api, locale, brightness);
          expect(t.takeException(), isNull, reason: 'no overflow');
          await capturePreview(t, 'agent-chips-$variant');
          Future<void> reveal(String option) async {
            await t.ensureVisible(find.byKey(Key('agent-config-$option')));
            await _frames(t);
          }

          // The model chip on screen, with its full value announced.
          await reveal('model');
          _chipShown(t, 'model', 'Model', 'Sample Router/lab/coder-9', size);
          await capturePreview(t, 'agent-chips-model-$variant');

          // Effort and mode: one frame where both fit, else one each.
          await reveal('effort');
          _chipShown(t, 'effort', 'Effort', 'High', size);
          final mode = find.byKey(const Key('agent-config-mode'));
          // Inside the options' clipping viewport, not just on screen.
          final options = t.getRect(
            find.byKey(const Key('agent-session-options')),
          );
          if (_shown(t, mode, size, within: options)) {
            _chipShown(t, 'mode', 'Session Mode', 'build', size);
            await capturePreview(t, 'agent-chips-effort-mode-$variant');
          } else {
            await capturePreview(t, 'agent-chips-effort-$variant');
            await reveal('mode');
            _chipShown(t, 'mode', 'Session Mode', 'build', size);
            await capturePreview(t, 'agent-chips-mode-$variant');
          }
          expect(t.takeException(), isNull, reason: 'no overflow');
        });

        testWidgets('agent chips with the longest model name ($variant)', (
          t,
        ) async {
          _size(t, size);
          const long =
              'router/lab/a-model-with-an-unusually-long-name-for-layout-checks';
          final base = previewAgentSettings();
          final settings = SessionSettings(
            configOptions: [
              for (final o in base.configOptions)
                o.id == 'model'
                    ? SessionConfigOption(
                        id: o.id,
                        name: o.name,
                        category: o.category,
                        description: o.description,
                        currentValue: long,
                        values: o.values,
                      )
                    : o,
            ],
          );
          final full = settings.configOptions.first.values
              .singleWhere((v) => v.value == long)
              .name;
          final api = FakeBridgeApi();
          await _openSession(t, api, locale, brightness, settings: settings);
          await t.ensureVisible(find.byKey(const Key('agent-config-model')));
          await _frames(t);
          expect(t.takeException(), isNull, reason: 'no overflow');
          _chipShown(t, 'model', 'Model', full, size);
          // The visible text is the label or its end after "…".
          final shown = t
              .widget<Text>(
                find.descendant(
                  of: find.byKey(const Key('agent-config-model')),
                  matching: find.byType(Text),
                ),
              )
              .data!;
          expect(
            shown == full ||
                (shown.startsWith('…') && full.endsWith(shown.substring(1))),
            isTrue,
            reason: '"$shown" is "$full" or its end',
          );
          await capturePreview(t, 'agent-chips-long-model-$variant');
        });

        testWidgets('model search with the keyboard up ($variant)', (t) async {
          _size(t, size);
          final api = FakeBridgeApi();
          await _openSession(t, api, locale, brightness);
          final chip = find.byKey(const Key('agent-config-model'));
          await t.ensureVisible(chip);
          await _frames(t);
          await t.tap(chip);
          await _frames(t);
          final search = find.byKey(const Key('agent-option-search'));
          expect(search, findsOneWidget);
          await t.enterText(search, 'lab/');
          final sheet = size.width < 720;
          final keyboard = sheet ? size.height * 0.4 : 0.0;
          if (sheet) t.view.viewInsets = FakeViewPadding(bottom: keyboard);
          await _frames(t);
          expect(t.takeException(), isNull, reason: 'no overflow');
          final top = size.height - keyboard;
          expect(t.getRect(search).bottom, lessThanOrEqualTo(top + 0.5));
          final row = find.byKey(
            const Key('agent-option-value-router/lab/coder-9'),
          );
          await t.ensureVisible(row);
          await _frames(t);
          _withinWidth(t, row, size);
          _operable(t, row, bottom: top);
          await capturePreview(t, 'agent-search-$variant');
          await t.tap(row);
          await _frames(t);
          expect(find.byKey(const Key('agent-option-list')), findsNothing);
          // Already selected: nothing is sent.
          expect(api.sessionConfigCalls, isEmpty);
        });
      }
    }
  }

  // The agent chooser under 3× text on a phone: section headings and tile
  // names stay whole, and both same-name preset tiles still say where they
  // come from.
  for (final brightness in Brightness.values) {
    for (final language in ['en', 'zh']) {
      final locale = Locale(language);
      final variant = 'phone390x3-${brightness.name}-$language';
      testWidgets('agent chooser with large text ($variant)', (t) async {
        const size = Size(390, 844);
        _size(t, size);
        t.platformDispatcher.textScaleFactorTestValue = 3;
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        final api = await _hostedApi();
        await _openDialog(
          t,
          api,
          locale,
          brightness,
          saved: const [_savedFixture, _savedAgent],
        );
        _withinWidth(t, find.byKey(const Key('agent-choice-grid')), size);
        await _captureSameName(
          t,
          size,
          locale,
          'hosting-same-name-$variant',
          large: true,
        );
      });
    }
  }

  // The manage page under 3× text on a tablet: too large for the device
  // column beside the detail, so it shows one level at a time, with the
  // identity, its status and the capability count whole on screen.
  for (final brightness in Brightness.values) {
    for (final language in ['en', 'zh']) {
      final locale = Locale(language);
      final variant = 'tablet800x3-${brightness.name}-$language';
      testWidgets('manage page with large text ($variant)', (t) async {
        const size = Size(800, 900);
        _size(t, size);
        t.platformDispatcher.textScaleFactorTestValue = 3;
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        try {
          final l10n = lookupAppLocalizations(locale);
          final api = await _hostedApi();
          await t.pumpWidget(
            _app(const ServicesScreen(), api, locale, brightness),
          );
          await t.pumpAndSettle();
          expect(t.takeException(), isNull, reason: 'no overflow');
          // A line of 3× text is taller than the bar's button, so the
          // label is never chosen here, whatever its width.
          expect(
            _primaryActionShown(t, size, l10n.servicesHostThisDevice),
            isFalse,
            reason: 'the icon form under 3× text',
          );

          // The device list: the identity and its whole status on screen,
          // inside the row that opens settings.
          final identity = find.byKey(const Key('identity-open-settings'));
          _usable(t, identity, size);
          final row = t.getRect(identity);
          for (final text in ['relay.example:7666', l10n.statusOnline]) {
            final shown = find.descendant(
              of: identity,
              matching: find.text(text),
            );
            expect(shown, findsOneWidget, reason: text);
            expect(
              _inside(t.getRect(shown), size, row),
              isTrue,
              reason: '$text inside the identity row $row',
            );
          }
          _oneLine(
            t,
            find.descendant(
              of: identity,
              matching: find.text(l10n.statusOnline),
            ),
          );
          await capturePreview(t, 'services-scaled-$variant');

          // One device's detail: its hosts, each the one row of its chat
          // service, whole inside the window.
          final tile = find.byWidgetPredicate((w) {
            final key = w.key;
            return key is ValueKey<String> &&
                key.value.startsWith('device-') &&
                !key.value.startsWith('device-capability-') &&
                key.value != 'device-back' &&
                key.value != 'device-clean-unreachable';
          });
          expect(tile, findsWidgets);
          await t.tap(tile.first);
          await t.pumpAndSettle();
          expect(t.takeException(), isNull, reason: 'no overflow (detail)');
          final section = find.text(l10n.localHostingSection);
          expect(section, findsOneWidget);
          final group = t.getRect(
            find.ancestor(of: section, matching: find.byType(GroupCard)).first,
          );
          expect(_inside(t.getRect(section), size, group), isTrue);
          _operable(t, find.byKey(const Key('device-back')));
          for (final name in ['default', 'fixture']) {
            final mark = find.byKey(Key('local-host-icon-$name'));
            expect(mark, findsOneWidget, reason: name);
            await t.ensureVisible(mark);
            await t.pumpAndSettle();
            final shown = t.getRect(
              find
                  .ancestor(of: section, matching: find.byType(GroupCard))
                  .first,
            );
            expect(_inside(t.getRect(mark), size, shown), isTrue, reason: name);
          }
          await capturePreview(t, 'services-scaled-detail-$variant');
          await t.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }
}
