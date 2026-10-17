// The model source and provider API choices keep their full names on a
// 320 and a 390 phone, an 800 tablet and a 1440 desktop width, English and
// Chinese, light and dark, at normal and 3× text, measured in the app's real
// bundled fonts: every line of each label is painted inside its choice, which
// may wrap but never cuts a name short. Pointer and keyboard choose, the
// choice is announced as selected, and a disabled section chooses nothing.
//
// Set PCX_UI_PREVIEW_DIR to also write each case as a PNG for review.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/model_service_section.dart';
import 'package:pocket_codex/src/theme.dart';

import 'support/ui_preview.dart';
import 'package:pocket_codex/src/app_icons.dart';

const _sizes = [
  ('phone320', Size(320, 640)),
  ('phone390', Size(390, 844)),
  ('tablet800', Size(800, 1100)),
  ('desktop1440', Size(1440, 900)),
];

const _sources = ['inherited', 'official', 'custom'];
const _protocols = ['responses', 'anthropic-messages', 'chat-completions'];

/// Every source and API offered, with the custom provider chosen so the API
/// choices are shown too.
ModelServiceDraft _draft() => ModelServiceDraft()
  ..restrict(const HostConfigSupport(sources: _sources, protocols: _protocols))
  ..source = 'custom';

Future<ModelServiceDraft> _mount(
  WidgetTester t, {
  required Size size,
  required Locale locale,
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool enabled = true,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final draft = _draft();
  await t.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: brightness == Brightness.light ? lightTheme() : darkTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: previewKey, child: child),
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ModelServiceSection(
            draft: draft,
            inherited: const SizedBox.shrink(),
            enabled: enabled,
          ),
        ),
      ),
    ),
  );
  await t.pump();
  return draft;
}

AppLocalizations _l10n(WidgetTester t) =>
    AppLocalizations.of(t.element(find.byType(ModelServiceSection)));

/// Each choice's key and its full label.
List<(String, String)> _labels(AppLocalizations l10n) => [
  ('host-source-inherited', l10n.hostSourceInherited),
  ('host-source-official', l10n.hostSourceOfficial),
  ('host-source-custom', l10n.hostSourceCustom),
  ('host-protocol-responses', l10n.hostProtocolResponses),
  ('host-protocol-anthropic-messages', l10n.hostProtocolAnthropic),
  ('host-protocol-chat-completions', l10n.hostProtocolChat),
];

bool _within(Rect inner, Rect outer) =>
    inner.left >= outer.left - 0.5 &&
    inner.top >= outer.top - 0.5 &&
    inner.right <= outer.right + 0.5 &&
    inner.bottom <= outer.bottom + 0.5;

/// [label] is painted whole inside the choice [key]: laid out at the width
/// it was given, the whole text (on as many lines as it needs) fits the
/// paragraph, the paragraph lies inside its choice and the choice inside the
/// screen width.
void _whole(WidgetTester t, String key, String label, Size screen) {
  final choice = find.byKey(Key(key));
  final text = find.descendant(of: choice, matching: find.text(label));
  expect(text, findsOneWidget, reason: '$key shows "$label"');
  final paragraph = t.renderObject<RenderParagraph>(text);
  expect(paragraph.didExceedMaxLines, isFalse, reason: '$key is cut');
  final full = TextPainter(
    text: paragraph.text,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
  )..layout(maxWidth: paragraph.size.width);
  expect(
    full.height,
    lessThanOrEqualTo(paragraph.size.height + 0.5),
    reason:
        '$key: "$label" needs ${full.height} in ${paragraph.size.width}, '
        'shown ${paragraph.size.height}',
  );
  for (final line in full.computeLineMetrics()) {
    expect(
      line.width,
      lessThanOrEqualTo(paragraph.size.width + 0.5),
      reason: '$key line ${line.lineNumber} is wider than its paragraph',
    );
  }
  full.dispose();
  final box = t.getRect(choice);
  expect(
    _within(t.getRect(text), box),
    isTrue,
    reason: '$key label ${t.getRect(text)} inside its choice $box',
  );
  expect(
    box.left >= -0.5 && box.right <= screen.width + 0.5,
    isTrue,
    reason: '$key $box inside the screen width ${screen.width}',
  );
}

/// Focus the choice [key] the way keyboard traversal would land on it.
Future<void> _focus(WidgetTester t, String key) async {
  final text = find.descendant(
    of: find.byKey(Key(key)),
    matching: find.byType(Text),
  );
  Focus.of(t.element(text)).requestFocus();
  await t.pump();
}

void main() {
  setUpAll(() => loadPreviewFonts(always: true));

  for (final (device, size) in _sizes) {
    for (final language in ['en', 'zh']) {
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 3.0]) {
          final name =
              'model-service-$device-${brightness.name}-$language-${scale}x';
          testWidgets('$name: every source and API label is whole', (t) async {
            await _mount(
              t,
              size: size,
              locale: Locale(language),
              brightness: brightness,
              scale: scale,
            );
            for (final (key, label) in _labels(_l10n(t))) {
              _whole(t, key, label, size);
            }
            expect(t.takeException(), isNull);
            await capturePreview(t, name);
          });
        }
      }
    }
  }

  testWidgets('pointer and keyboard choose, and the choice is announced', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    final draft = await _mount(
      t,
      size: const Size(320, 640),
      locale: const Locale('zh'),
      brightness: Brightness.dark,
      scale: 3,
    );
    final anthropic = find.byKey(const Key('host-protocol-anthropic-messages'));
    await t.ensureVisible(anthropic);
    await t.pump();
    await t.tap(anthropic);
    await t.pump();
    expect(draft.protocol, 'anthropic-messages');
    expect(
      t.getSemantics(anthropic),
      isSemantics(
        label: 'Anthropic Messages',
        isButton: true,
        isSelected: true,
        hasEnabledState: true,
        isEnabled: true,
        isInMutuallyExclusiveGroup: true,
        hasTapAction: true,
      ),
    );
    expect(
      find.descendant(of: anthropic, matching: find.byIcon(AppIcons.check)),
      findsOneWidget,
    );
    final responses = find.byKey(const Key('host-protocol-responses'));
    expect(
      t.getSemantics(responses),
      isSemantics(
        label: 'OpenAI Responses',
        isButton: true,
        isSelected: false,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    expect(
      find.descendant(of: responses, matching: find.byIcon(AppIcons.check)),
      findsNothing,
    );

    await _focus(t, 'host-protocol-chat-completions');
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await t.pump();
    expect(draft.protocol, 'chat-completions', reason: 'Space chooses');
    await _focus(t, 'host-protocol-responses');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(draft.protocol, 'responses', reason: 'Enter chooses');
    expect(t.getSemantics(responses), isSemantics(isSelected: true));

    await _focus(t, 'host-source-inherited');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(draft.source, 'inherited');
    expect(
      find.byKey(const Key('host-protocol-responses')),
      findsNothing,
      reason: 'the API choice belongs to the custom provider',
    );
    expect(t.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('a disabled section shows every choice whole and chooses '
      'nothing', (t) async {
    final semantics = t.ensureSemantics();
    const size = Size(320, 640);
    final draft = await _mount(
      t,
      size: size,
      locale: const Locale('en'),
      scale: 3,
      enabled: false,
    );
    for (final (key, label) in _labels(_l10n(t))) {
      _whole(t, key, label, size);
    }
    final anthropic = find.byKey(const Key('host-protocol-anthropic-messages'));
    await t.ensureVisible(anthropic);
    await t.pump();
    await t.tap(anthropic, warnIfMissed: false);
    await t.pump();
    expect(draft.protocol, 'responses', reason: 'a tap chooses nothing');
    expect(
      t.getSemantics(anthropic),
      isSemantics(
        isButton: true,
        isSelected: false,
        hasEnabledState: true,
        isEnabled: false,
        hasTapAction: false,
      ),
    );
    expect(
      t.getSemantics(find.byKey(const Key('host-protocol-responses'))),
      isSemantics(isSelected: true, isEnabled: false),
      reason: 'the current choice is still announced',
    );
    final text = find.descendant(of: anthropic, matching: find.byType(Text));
    expect(
      Focus.of(t.element(text)).canRequestFocus,
      isFalse,
      reason: 'not reachable by keyboard',
    );
    expect(t.takeException(), isNull);
    semantics.dispose();
  });
}
