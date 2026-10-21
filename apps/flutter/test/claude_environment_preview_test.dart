import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/hosting/claude_environment_section.dart';
import 'package:pocox/src/hosting/claude_environment_field.dart';
import 'package:pocox/src/hosting/claude_preparation_progress.dart';
import 'package:pocox/src/theme.dart';

import 'support/ui_preview.dart';
import 'package:pocox/src/app_icons.dart';

final _catalog = [
  const ClaudeVariable(name: 'ANTHROPIC_BASE_URL', group: 'connection'),
  const ClaudeVariable(
    name: 'ANTHROPIC_AUTH_TOKEN',
    group: 'connection',
    secret: true,
  ),
  const ClaudeVariable(
    name: 'ANTHROPIC_API_KEY',
    group: 'connection',
    secret: true,
  ),
  const ClaudeVariable(
    name: 'CLAUDE_CODE_OAUTH_TOKEN',
    group: 'connection',
    secret: true,
  ),
  for (final name in [
    'ANTHROPIC_MODEL',
    'ANTHROPIC_DEFAULT_OPUS_MODEL',
    'ANTHROPIC_DEFAULT_SONNET_MODEL',
    'ANTHROPIC_DEFAULT_HAIKU_MODEL',
    'ANTHROPIC_CUSTOM_MODEL_OPTION',
    'CLAUDE_CODE_SUBAGENT_MODEL',
  ])
    ClaudeVariable(name: name, group: 'models'),
  const ClaudeVariable(
    name: 'CLAUDE_CODE_EFFORT_LEVEL',
    group: 'reasoning',
    choices: ['auto', 'low', 'medium', 'high', 'xhigh', 'max'],
  ),
  const ClaudeVariable(name: 'MAX_THINKING_TOKENS', group: 'reasoning'),
  const ClaudeVariable(
    name: 'CLAUDE_CODE_MAX_OUTPUT_TOKENS',
    group: 'reasoning',
  ),
  for (final name in [
    'CLAUDE_CODE_DISABLE_THINKING',
    'CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING',
  ])
    ClaudeVariable(name: name, group: 'reasoning', choices: ['0', '1']),
  const ClaudeVariable(name: 'API_TIMEOUT_MS', group: 'network'),
  const ClaudeVariable(name: 'HTTP_PROXY', group: 'network', secret: true),
  const ClaudeVariable(name: 'HTTPS_PROXY', group: 'network', secret: true),
  const ClaudeVariable(name: 'NO_PROXY', group: 'network'),
  for (final name in [
    'DISABLE_PROMPT_CACHING',
    'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC',
  ])
    ClaudeVariable(name: name, group: 'network', choices: ['0', '1']),
];

Future<void> _frames(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _show(WidgetTester t, Finder target) async {
  await t.ensureVisible(target);
  await _frames(t);
}

Future<void> _mount(
  WidgetTester t,
  ClaudeEnvironmentDraft draft, {
  required Size size,
  required String language,
  required Brightness brightness,
  required double scale,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      theme: brightness == Brightness.light ? lightTheme() : darkTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: previewKey, child: child!),
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const ClaudePreparationProgress(
                      setup: AcpClaudeSetup(
                        state: 'running',
                        stage: 'downloading',
                        run: 1,
                        elapsedMs: 42000,
                        downloadedBytes: 3400000,
                        downloadBytesPerSecond: 1800000,
                      ),
                    ),
                    const SizedBox(height: 24),
                    ListenableBuilder(
                      listenable: draft,
                      builder: (_, _) => ClaudeEnvironmentSection(
                        draft: draft,
                        enabled: true,
                        customProvider: false,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _frames(t);
}

void main() {
  setUpAll(() async {
    // Bundled fonts only: the source-tree Noto Sans SC for the Apple CJK face, so previews
    // do not depend on the fonts installed on this machine.
    await loadPreviewFonts(always: true);
    await (FontLoader('PingFang SC')..addFont(
          File(
            'assets/fonts/NotoSansSC-VariableFont_wght.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
  for (final width in [320.0, 390.0, 800.0, 1440.0]) {
    for (final language in ['en', 'zh']) {
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 2.0]) {
          final scene =
              '${width.toInt()}-$language-${brightness.name}-${scale.toInt()}x';
          testWidgets(
            'Claude environment and preparation stay usable ($scene)',
            (t) async {
              final draft = ClaudeEnvironmentDraft()
                ..variables = _catalog
                ..load({
                  'ANTHROPIC_AUTH_TOKEN': null,
                  'ANTHROPIC_DEFAULT_OPUS_MODEL': 'provider.exact-opus',
                  'CLAUDE_CODE_EFFORT_LEVEL': 'high',
                  'HTTPS_PROXY': null,
                  'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
                });
              await _mount(
                t,
                draft,
                size: Size(width, 1000),
                language: language,
                brightness: brightness,
                scale: scale,
              );
              expect(t.takeException(), isNull);
              await capturePreview(t, 'claude-$scene-overview');
              for (final group in [
                'connection',
                'models',
                'reasoning',
                'network',
              ]) {
                final header = find.byKey(Key('claude-env-group-$group'));
                await _show(t, header);
                await t.tap(header);
                await _frames(t);
                await _show(t, header);
                await capturePreview(t, 'claude-$scene-$group');
                for (final variable in _catalog.where(
                  (v) => v.group == group,
                )) {
                  if (claudeCredentials.contains(variable.name) &&
                      !draft.custom(variable.name)) {
                    continue;
                  }
                  final text = find.text(
                    variable.name.replaceAll('_', '_\u200B'),
                  );
                  await _show(t, text);
                  expect(
                    t.renderObject<RenderParagraph>(text).didExceedMaxLines,
                    isFalse,
                  );
                  final rect = t.getRect(text);
                  expect(rect.left, greaterThanOrEqualTo(0));
                  expect(rect.right, lessThanOrEqualTo(width));
                }
                expect(t.takeException(), isNull);
                await _show(t, header);
                await t.tap(header);
                await _frames(t);
              }
              expect(draft.input['ANTHROPIC_AUTH_TOKEN'], isNull);
              expect(draft.input['HTTPS_PROXY'], isNull);
              await t.pumpWidget(const SizedBox());
              draft.dispose();
            },
            variant: const TargetPlatformVariant({TargetPlatform.macOS}),
          );
        }
      }
    }
  }

  testWidgets(
    'environment groups and overrides work from the keyboard',
    (t) async {
      final semantics = t.ensureSemantics();
      try {
        final draft = ClaudeEnvironmentDraft()..variables = _catalog;
        await _mount(
          t,
          draft,
          size: const Size(800, 1000),
          language: 'en',
          brightness: Brightness.light,
          scale: 1,
        );
        final header = find.byKey(const Key('claude-env-group-models'));
        final glyph = find.descendant(
          of: header,
          matching: find.byIcon(AppIcons.expand_more),
        );
        await _show(t, header);
        Focus.of(t.element(glyph)).requestFocus();
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await _frames(t);
        expect(
          t.getSemantics(header),
          isSemantics(hasExpandedState: true, isExpanded: true),
        );
        final row = find.byKey(
          const Key('claude-env-row-ANTHROPIC_DEFAULT_OPUS_MODEL'),
        );
        final name = find.descendant(
          of: row,
          matching: find.byType(ClaudeVariableName),
        );
        await _show(t, name);
        Focus.of(t.element(name)).requestFocus();
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.space);
        await _frames(t);
        expect(draft.custom('ANTHROPIC_DEFAULT_OPUS_MODEL'), isTrue);
        final field = find.byKey(
          const Key('claude-env-value-ANTHROPIC_DEFAULT_OPUS_MODEL'),
        );
        await t.enterText(field, 'provider.keyboard');
        await _frames(t);
        expect(
          draft.input['ANTHROPIC_DEFAULT_OPUS_MODEL'],
          'provider.keyboard',
        );
        await _show(t, header);
        Focus.of(t.element(glyph)).requestFocus();
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.space);
        await _frames(t);
        expect(
          t.getSemantics(header),
          isSemantics(hasExpandedState: true, isExpanded: false),
        );
        expect(field, findsNothing);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        draft.dispose();
      } finally {
        semantics.dispose();
      }
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );
}
