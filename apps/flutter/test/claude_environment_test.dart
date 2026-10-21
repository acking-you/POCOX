import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/hosting/model_service_section.dart';
import 'package:pocox/src/hosting/claude_environment_section.dart';
import 'package:pocox/src/theme.dart';
import 'support/ui_preview.dart';

const _variables = [
  ClaudeVariable(
    name: 'ANTHROPIC_AUTH_TOKEN',
    group: 'connection',
    secret: true,
  ),
  ClaudeVariable(name: 'ANTHROPIC_DEFAULT_OPUS_MODEL', group: 'models'),
  ClaudeVariable(
    name: 'CLAUDE_CODE_EFFORT_LEVEL',
    group: 'reasoning',
    choices: ['auto', 'low', 'medium', 'high'],
  ),
];

/// Every kind of row: URL, the three credentials, the default model (hidden
/// by a custom provider), an alias, choices and long-named flags.
const _catalog = [
  ClaudeVariable(name: 'ANTHROPIC_BASE_URL', group: 'connection'),
  ClaudeVariable(
    name: 'ANTHROPIC_AUTH_TOKEN',
    group: 'connection',
    secret: true,
  ),
  ClaudeVariable(name: 'ANTHROPIC_API_KEY', group: 'connection', secret: true),
  ClaudeVariable(
    name: 'CLAUDE_CODE_OAUTH_TOKEN',
    group: 'connection',
    secret: true,
  ),
  ClaudeVariable(name: 'ANTHROPIC_MODEL', group: 'models'),
  ClaudeVariable(name: 'ANTHROPIC_DEFAULT_OPUS_MODEL', group: 'models'),
  ClaudeVariable(
    name: 'CLAUDE_CODE_EFFORT_LEVEL',
    group: 'reasoning',
    choices: ['auto', 'low', 'medium', 'high', 'xhigh', 'max'],
  ),
  ClaudeVariable(name: 'HTTPS_PROXY', group: 'network', secret: true),
  ClaudeVariable(
    name: 'DISABLE_PROMPT_CACHING',
    group: 'network',
    choices: ['0', '1'],
  ),
  ClaudeVariable(
    name: 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC',
    group: 'network',
    choices: ['0', '1'],
  ),
];

Future<void> _mount(
  WidgetTester t,
  ClaudeEnvironmentDraft d, {
  String locale = 'en',
  bool customProvider = false,
  bool enabled = true,
  double textScale = 1,
  Size size = const Size(800, 1400),
  ThemeData? theme,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      locale: Locale(locale),
      theme: theme ?? ThemeData(fontFamily: 'Noto Sans SC'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ListenableBuilder(
                listenable: d,
                builder: (_, _) => ClaudeEnvironmentSection(
                  draft: d,
                  enabled: enabled,
                  customProvider: customProvider,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> _tap(WidgetTester t, String key) async {
  final target = find.byKey(Key(key));
  await t.ensureVisible(target);
  await t.pumpAndSettle();
  await t.tap(target);
  await t.pumpAndSettle();
}

ClaudeEnvironmentDraft _draft(Map<String, String?> values) =>
    ClaudeEnvironmentDraft()
      ..variables = _catalog
      ..load(values);

void main() {
  setUpAll(() => loadPreviewFonts(always: true));
  test(
    'unset defaults, secret retention and reverting to inherit are distinct',
    () {
      final d = ModelServiceDraft()
        ..restrict(const HostConfigSupport(claudeVariables: _variables));
      addTearDown(d.dispose);
      expect(d.input.claudeEnv, isEmpty);
      d.load(
        const HostConfig(
          claudeEnv: {
            'ANTHROPIC_AUTH_TOKEN': null,
            'ANTHROPIC_DEFAULT_OPUS_MODEL': 'provider.exact',
          },
        ),
      );
      expect(d.environment.field('ANTHROPIC_AUTH_TOKEN').text, isEmpty);
      expect(d.dirty, isFalse);
      expect(d.input.claudeEnv!['ANTHROPIC_AUTH_TOKEN'], isNull);
      d.environment.field('ANTHROPIC_AUTH_TOKEN').text = 'replacement';
      expect(d.input.claudeEnv!['ANTHROPIC_AUTH_TOKEN'], 'replacement');
      expect(d.dirty, isTrue);
      d.environment.setOverride('ANTHROPIC_AUTH_TOKEN', false);
      expect(d.input.claudeEnv!.containsKey('ANTHROPIC_AUTH_TOKEN'), isFalse);
      d.environment.setOverride('CLAUDE_CODE_EFFORT_LEVEL', true);
      expect(d.environment.valid, isFalse);
      d.environment.field('CLAUDE_CODE_EFFORT_LEVEL').text = 'high';
      expect(d.environment.valid, isTrue);
    },
  );

  for (final locale in ['en', 'zh']) {
    testWidgets(
      '$locale narrow large text editor keeps secrets masked and inheritance reachable',
      (t) async {
        final d = _draft({'ANTHROPIC_AUTH_TOKEN': null});
        await _mount(
          t,
          d,
          locale: locale,
          textScale: 2,
          size: const Size(320, 900),
        );
        for (final group in ['connection', 'models', 'reasoning', 'network']) {
          await _tap(t, 'claude-env-group-$group');
        }
        final field = find.byKey(
          const Key('claude-env-value-ANTHROPIC_AUTH_TOKEN'),
        );
        await t.ensureVisible(field);
        await t.pumpAndSettle();
        expect(t.widget<TextField>(field).obscureText, isTrue);
        expect(t.widget<TextField>(field).controller!.text, isEmpty);
        // The long flag name wraps inside a 320px column at 2× text.
        await _tap(
          t,
          'claude-env-override-CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC',
        );
        expect(t.takeException(), isNull);
        await _tap(t, 'claude-env-credential-inherit');
        await _tap(
          t,
          'claude-env-override-CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC',
        );
        expect(d.input, isEmpty);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        d.dispose();
      },
    );
  }

  testWidgets('closed groups say what is inherited and what changed', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    final d = _draft({'ANTHROPIC_DEFAULT_OPUS_MODEL': 'provider.exact-opus'});
    await _mount(t, d);
    expect(find.text('1 override'), findsOneWidget);
    expect(find.text('Opus alias model'), findsOneWidget);
    expect(find.text('All inherited'), findsNWidgets(3));
    expect(
      find.byKey(const Key('claude-env-value-ANTHROPIC_DEFAULT_OPUS_MODEL')),
      findsNothing,
      reason: 'groups start closed',
    );
    final header = find.byKey(const Key('claude-env-group-models'));
    expect(
      t.getSemantics(header),
      isSemantics(isButton: true, hasExpandedState: true, isExpanded: false),
    );
    await _tap(t, 'claude-env-group-models');
    expect(
      t.getSemantics(header),
      isSemantics(hasExpandedState: true, isExpanded: true),
    );
    final value = find.byKey(
      const Key('claude-env-value-ANTHROPIC_DEFAULT_OPUS_MODEL'),
    );
    expect(t.widget<TextField>(value).controller!.text, 'provider.exact-opus');
    expect(t.widget<TextField>(value).obscureText, isFalse);
    expect(
      find.text('ANTHROPIC_\u200BDEFAULT_\u200BOPUS_\u200BMODEL'),
      findsOneWidget,
      reason: 'the exact name, breakable at underscores',
    );
    // Back to inherit: the value leaves the input, the summary follows.
    await _tap(t, 'claude-env-override-ANTHROPIC_DEFAULT_OPUS_MODEL');
    expect(d.input, isEmpty);
    expect(value, findsNothing);
    expect(find.text('Inherits everything'), findsOneWidget);
    semantics.dispose();
    await t.pumpWidget(const SizedBox());
    d.dispose();
  });

  testWidgets('the credential is one choice and a new one needs a value', (
    t,
  ) async {
    final d = _draft({'ANTHROPIC_AUTH_TOKEN': null});
    await _mount(t, d);
    await _tap(t, 'claude-env-group-connection');
    expect(find.text('Stored securely · leave blank to keep'), findsOneWidget);
    await _tap(t, 'claude-env-override-ANTHROPIC_API_KEY');
    expect(d.custom('ANTHROPIC_API_KEY'), isTrue);
    expect(d.custom('ANTHROPIC_AUTH_TOKEN'), isFalse);
    expect(
      find.byKey(const Key('claude-env-value-ANTHROPIC_AUTH_TOKEN')),
      findsNothing,
    );
    final key = find.byKey(const Key('claude-env-value-ANTHROPIC_API_KEY'));
    expect(t.widget<TextField>(key).obscureText, isTrue);
    expect(d.valid, isFalse);
    expect(find.text('1 value needed'), findsOneWidget);
    expect(find.text('A value is still needed'), findsOneWidget);
    expect(
      find.text('Needs a value, or switch back to inherit.'),
      findsOneWidget,
    );
    await t.enterText(key, 'sk-new');
    await t.pumpAndSettle();
    expect(d.valid, isTrue);
    expect(d.input, {'ANTHROPIC_API_KEY': 'sk-new'});
    expect(find.text('1 value needed'), findsNothing);
    await _tap(t, 'claude-env-credential-inherit');
    expect(d.input, isEmpty);
    await t.pumpWidget(const SizedBox());
    d.dispose();
  });

  testWidgets('choices and flags store their exact values', (t) async {
    final d = _draft(const {});
    await _mount(t, d);
    await _tap(t, 'claude-env-group-reasoning');
    await _tap(t, 'claude-env-override-CLAUDE_CODE_EFFORT_LEVEL');
    await _tap(t, 'claude-env-choice-CLAUDE_CODE_EFFORT_LEVEL-xhigh');
    await _tap(t, 'claude-env-group-network');
    await _tap(t, 'claude-env-override-DISABLE_PROMPT_CACHING');
    expect(find.text('On'), findsWidgets);
    await _tap(t, 'claude-env-choice-DISABLE_PROMPT_CACHING-1');
    expect(d.input, {
      'CLAUDE_CODE_EFFORT_LEVEL': 'xhigh',
      'DISABLE_PROMPT_CACHING': '1',
    });
    await _tap(t, 'claude-env-choice-DISABLE_PROMPT_CACHING-0');
    expect(d.input['DISABLE_PROMPT_CACHING'], '0');
    expect(find.text('2 overrides'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    d.dispose();
  });

  testWidgets('a custom provider hides its connection fields and keeps their '
      'values dormant', (t) async {
    final d = _draft({
      'ANTHROPIC_BASE_URL': 'https://gateway.example',
      'ANTHROPIC_MODEL': 'provider.default',
    });
    await _mount(t, d, customProvider: true);
    expect(find.byKey(const Key('claude-env-group-connection')), findsNothing);
    expect(find.byKey(const Key('claude-env-provider-wins')), findsOneWidget);
    expect(find.byKey(const Key('claude-env-dormant')), findsOneWidget);
    expect(find.text('Inherits everything'), findsOneWidget);
    await _tap(t, 'claude-env-group-models');
    expect(
      find.byKey(const Key('claude-env-override-ANTHROPIC_MODEL')),
      findsNothing,
    );
    expect(d.input, {
      'ANTHROPIC_BASE_URL': 'https://gateway.example',
      'ANTHROPIC_MODEL': 'provider.default',
    });
    await t.pumpWidget(const SizedBox());
    d.dispose();
  });

  testWidgets('incomplete inactive credentials remain reachable for repair', (
    t,
  ) async {
    final d = _draft({})..setOverride('ANTHROPIC_AUTH_TOKEN', true);
    await _mount(t, d, customProvider: true);
    expect(d.valid, isFalse);
    await _tap(t, 'claude-env-edit-dormant');
    await _tap(t, 'claude-env-group-connection');
    final value = find.byKey(
      const Key('claude-env-value-ANTHROPIC_AUTH_TOKEN'),
    );
    await t.ensureVisible(value);
    await t.pumpAndSettle();
    expect(t.widget<TextField>(value).obscureText, isTrue);
    await t.enterText(value, 'fixture-token');
    await t.pumpAndSettle();
    expect(d.valid, isTrue);
    expect(d.input['ANTHROPIC_AUTH_TOKEN'], 'fixture-token');
    await _tap(t, 'claude-env-edit-dormant');
    expect(find.byKey(const Key('claude-env-group-connection')), findsNothing);
    expect(d.input['ANTHROPIC_AUTH_TOKEN'], 'fixture-token');
    await t.pumpWidget(const SizedBox());
    d.dispose();
  });

  test(
    'non-Claude save clears overrides but switching back retains the draft',
    () {
      final d = ModelServiceDraft()
        ..restrict(const HostConfigSupport(claudeVariables: _variables))
        ..load(const HostConfig(claudeEnv: {'ANTHROPIC_AUTH_TOKEN': null}));
      addTearDown(d.dispose);
      d.restrict(const HostConfigSupport());
      expect(d.input.claudeEnv, isEmpty);
      expect(d.dirty, isTrue);
      d.restrict(const HostConfigSupport(claudeVariables: _variables));
      expect(d.input.claudeEnv, {'ANTHROPIC_AUTH_TOKEN': null});
      expect(d.dirty, isFalse);
      d.environment.field('ANTHROPIC_AUTH_TOKEN').text = 'draft-token';
      d.restrict(const HostConfigSupport());
      expect(d.input.claudeEnv, isEmpty);
      d.restrict(const HostConfigSupport(claudeVariables: _variables));
      expect(d.input.claudeEnv, {'ANTHROPIC_AUTH_TOKEN': 'draft-token'});
    },
  );

  testWidgets('a busy editor shows the state but changes nothing', (t) async {
    final d = _draft({'CLAUDE_CODE_EFFORT_LEVEL': 'high'});
    await _mount(t, d, enabled: false, theme: darkTheme());
    await _tap(t, 'claude-env-group-reasoning');
    expect(
      t
          .widget<Switch>(
            find.byKey(
              const Key('claude-env-override-CLAUDE_CODE_EFFORT_LEVEL'),
            ),
          )
          .onChanged,
      isNull,
    );
    await _tap(t, 'claude-env-choice-CLAUDE_CODE_EFFORT_LEVEL-low');
    expect(d.input, {'CLAUDE_CODE_EFFORT_LEVEL': 'high'});
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    d.dispose();
  });

  for (final width in [390.0, 1440.0]) {
    testWidgets('every group opens cleanly at ${width.toInt()}px', (t) async {
      final d = _draft({
        'ANTHROPIC_AUTH_TOKEN': null,
        'HTTPS_PROXY': null,
        'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
      });
      await _mount(t, d, locale: 'zh', size: Size(width, 2400));
      for (final group in ['connection', 'models', 'reasoning', 'network']) {
        await _tap(t, 'claude-env-group-$group');
      }
      expect(
        t
            .widget<TextField>(
              find.byKey(const Key('claude-env-value-HTTPS_PROXY')),
            )
            .obscureText,
        isTrue,
      );
      expect(find.text('2 项覆盖'), findsNothing);
      expect(find.text('3 项覆盖'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      d.dispose();
    });
  }
}
