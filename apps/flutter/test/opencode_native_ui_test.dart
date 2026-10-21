// Pure pieces of the native OpenCode UI: draft options, the command list,
// the host that continues a native session, restore records, permission
// labels and multiple-choice questions.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations_en.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/hosting/host_restore.dart';
import 'package:pocox/src/native_hosts.dart';
import 'package:pocox/src/screens/app_session/agent_permission_card.dart';
import 'package:pocox/src/screens/app_session/agent_session_options.dart';
import 'package:pocox/src/screens/app_session/command_palette.dart';
import 'package:pocox/src/screens/app_session/user_input_card.dart';
import 'package:pocox/src/ui_prefs.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

const _model = SessionConfigOption(
  id: 'model',
  name: 'Model',
  category: 'model',
  currentValue: 'anthropic/sonnet',
  values: [
    SessionConfigValue(value: 'anthropic/sonnet', name: 'Sonnet'),
    SessionConfigValue(value: 'openai/gpt', name: 'GPT'),
  ],
);

SessionConfigOption _variant({bool grouped = true}) => SessionConfigOption(
  id: 'variant',
  name: 'Variant',
  category: 'thought_level',
  currentValue: 'high',
  values: [
    SessionConfigValue(
      value: 'high',
      name: 'High',
      group: grouped ? 'anthropic/sonnet' : null,
    ),
    SessionConfigValue(
      value: 'minimal',
      name: 'Minimal',
      group: grouped ? 'openai/gpt' : null,
    ),
  ],
);

AppServeStatus _acp(String name, String profile) => AppServeStatus(
  name: name,
  device: 'local',
  alive: true,
  appServiceKey: 'pcx:local:acp:$name',
  provider: 'acp',
  profileId: profile,
);

void main() {
  final l10n = AppLocalizationsEn();

  group('draftSessionSettings', () {
    test('shows the host defaults until something is chosen', () {
      final s = draftSessionSettings(
        SessionSettings(configOptions: [_model, _variant()]),
        const {},
      );
      expect(s.configOptions.map((o) => o.currentValue), [
        'anthropic/sonnet',
        'high',
      ]);
    });

    test('offers only the chosen model\'s variants, starting at none', () {
      final s = draftSessionSettings(
        SessionSettings(configOptions: [_model, _variant()]),
        const {'model': 'openai/gpt'},
        defaultName: 'Default',
      );
      final variant = s.configOptions.singleWhere((o) => o.id == 'variant');
      // A new model starts without a variant (the host resets it), so that
      // is what is shown, never a variant nothing would apply.
      expect(variant.values.map((v) => v.value), ['', 'minimal']);
      expect(variant.currentLabel, 'Default');
      expect(variant.currentValue, '');
      final chosen = draftSessionSettings(
        SessionSettings(configOptions: [_model, _variant()]),
        const {'model': 'openai/gpt', 'variant': 'minimal'},
      );
      expect(
        chosen.configOptions.singleWhere((o) => o.id == 'variant').currentValue,
        'minimal',
      );
    });

    test('what a draft shows is exactly what its choices apply', () {
      final base = SessionSettings(configOptions: [_model, _variant()]);
      var choices = <String, String>{};
      choices = draftChoiceAfter(base, choices, 'model', 'openai/gpt');
      expect(choices, {'model': 'openai/gpt'});
      choices = draftChoiceAfter(base, choices, 'variant', 'minimal');
      expect(choices, {'model': 'openai/gpt', 'variant': 'minimal'});
      // Back to "no variant": nothing to apply for it.
      expect(draftChoiceAfter(base, choices, 'variant', ''), {
        'model': 'openai/gpt',
      });
      // Another model drops the variant choice, as the host does.
      choices = draftChoiceAfter(base, choices, 'model', 'anthropic/sonnet');
      expect(choices, isEmpty, reason: 'the default model is no choice');
      final shown = draftSessionSettings(base, choices);
      expect(shown.configOptions.map((o) => o.currentValue), [
        'anthropic/sonnet',
        'high',
      ]);
    });

    test('the native catalog shape: inherited model, per-model defaults', () {
      // As the bridge reports a draft: model "" (inherited), every model's
      // variants grouped by its key, each with its own "" default.
      const base = SessionSettings(
        configOptions: [
          SessionConfigOption(
            id: 'model',
            name: 'Model',
            category: 'model',
            currentValue: '',
            values: [
              SessionConfigValue(value: '', name: 'Inherited'),
              SessionConfigValue(value: 'a/one', name: 'One'),
              SessionConfigValue(value: 'b/two', name: 'Two'),
            ],
          ),
          SessionConfigOption(
            id: 'variant',
            name: 'Variant',
            category: 'thought_level',
            currentValue: '',
            values: [
              SessionConfigValue(value: '', name: 'Default', group: 'a/one'),
              SessionConfigValue(value: 'high', name: 'high', group: 'a/one'),
              SessionConfigValue(value: '', name: 'Default', group: 'b/two'),
              SessionConfigValue(value: 'high', name: 'high', group: 'b/two'),
            ],
          ),
        ],
      );
      // No variant without a model: the host refuses one.
      expect(draftSessionSettings(base, const {}).configOptions.length, 1);
      var choices = draftChoiceAfter(base, const {}, 'model', 'a/one');
      var variant = draftSessionSettings(
        base,
        choices,
      ).configOptions.singleWhere((o) => o.id == 'variant');
      expect(variant.values.map((v) => v.value), ['', 'high']);
      expect(variant.currentLabel, 'Default');
      choices = draftChoiceAfter(base, choices, 'variant', 'high');
      // A variant of the same name on another model is not carried over.
      choices = draftChoiceAfter(base, choices, 'model', 'b/two');
      expect(choices, {'model': 'b/two'});
      variant = draftSessionSettings(
        base,
        choices,
      ).configOptions.singleWhere((o) => o.id == 'variant');
      expect(variant.currentValue, '');
      expect(draftChoiceAfter(base, choices, 'model', ''), isEmpty);
    });

    test('withholds ungrouped variants once another model is chosen', () {
      final s = draftSessionSettings(
        SessionSettings(configOptions: [_model, _variant(grouped: false)]),
        const {'model': 'openai/gpt'},
      );
      expect(s.configOptions.map((o) => o.id), ['model']);
    });

    test('ignores a choice the option does not offer', () {
      final s = draftSessionSettings(
        SessionSettings(configOptions: [_model]),
        const {'model': 'gone/model'},
      );
      expect(s.configOptions.single.currentValue, 'anthropic/sonnet');
    });
  });

  group('command list', () {
    const commands = [
      AgentCommand(name: 'review', source: 'command'),
      AgentCommand(name: 'init', source: 'command'),
      AgentCommand(name: 'pr-review', source: 'mcp'),
    ];

    test('only a bare /name prefix is a query', () {
      expect(commandQuery('/'), '');
      expect(commandQuery('/rev'), 'rev');
      expect(commandQuery('/review now'), isNull);
      expect(commandQuery('/a\nb'), isNull);
      expect(commandQuery('review'), isNull);
      expect(commandQuery(' /review'), isNull);
    });

    test('prefix matches come before other matches, in engine order', () {
      expect(filterCommands(commands, '').length, 3);
      expect(filterCommands(commands, 'rev').map((c) => c.name), [
        'review',
        'pr-review',
      ]);
      expect(filterCommands(commands, 'REV').first.name, 'review');
      expect(filterCommands(commands, 'zzz'), isEmpty);
    });
  });

  group('nativeContinueHost', () {
    final open = FakeBridgeApi.openCodeHost('opencode');
    // Its own database holds none of this computer's OpenCode sessions.
    final apart = FakeBridgeApi.openCodeHost('apart', separateHistory: true);
    final hosts = [
      apart,
      _acp('claude', 'claude'),
      _acp('claude-2', 'claude'),
      _acp('gemini', 'gemini'),
      open,
    ];

    test('matches the provider and prefers the last used host', () {
      expect(nativeContinueHost(hosts, 'opencode'), same(open));
      expect(
        nativeContinueHost(hosts, 'opencode', preferred: apart.appServiceKey),
        same(open),
      );
      expect(nativeContinueHost([apart], 'opencode'), isNull);
      expect(nativeContinueHost(hosts, 'claude')!.name, 'claude');
      expect(
        nativeContinueHost(
          hosts,
          'claude',
          preferred: 'pcx:local:acp:claude-2',
        )!.name,
        'claude-2',
      );
      expect(nativeContinueHost(hosts, 'codex'), isNull);
    });

    test("a Grok host continues only from the user's own Grok home", () {
      AppServeStatus grok(String name, String source) => AppServeStatus(
        name: name,
        device: 'local',
        alive: true,
        appServiceKey: 'pcx:local:acp:$name',
        provider: 'acp',
        profileId: 'grok',
        configSource: source,
      );
      // A custom provider's host keeps sessions in a Grok home of its own.
      final custom = grok('gateway', 'custom');
      expect(nativeContinueHost([custom], 'grok'), isNull);
      expect(
        nativeContinueHost([custom, grok('grok', 'official')], 'grok')!.name,
        'grok',
      );
      expect(
        nativeContinueHost([grok('mine', 'inherited')], 'grok'),
        isNotNull,
      );
      expect(nativeContinueHost([_acp('claude', 'claude')], 'grok'), isNull);
    });

    test('a stopped or unregistered host continues nothing', () {
      expect(
        nativeContinueHost([
          const AppServeStatus(
            name: 'opencode',
            device: 'local',
            provider: 'opencode',
            appServiceKey: 'pcx:local:opencode:opencode',
          ),
        ], 'opencode'),
        isNull,
      );
      expect(
        nativeContinueHost([_acp('claude', 'claude')], 'opencode'),
        isNull,
      );
    });
  });

  group('OpenCode restore records', () {
    test('round-trip, and the retired ACP preset is dropped', () {
      final prefs = UiPrefs.fromJson({
        'autoHostOpenCode': {'name': 'opencode', 'binary': '/bin/opencode'},
        'acpAgents': [
          {
            'profileId': 'opencode',
            'displayName': 'OpenCode',
            'program': 'opencode',
            'args': ['acp'],
          },
          {
            'profileId': 'claude',
            'displayName': 'Claude',
            'program': 'claude-agent-acp',
            'args': <String>[],
          },
        ],
        'autoHostAcp': [
          {
            'name': 'opencode',
            'spec': {
              'profileId': 'opencode',
              'displayName': 'OpenCode',
              'program': 'opencode',
              'args': ['acp'],
            },
          },
        ],
      });
      expect(prefs.autoHostOpenCode?.name, 'opencode');
      expect(prefs.autoHostOpenCode?.binary, '/bin/opencode');
      expect(prefs.acpAgents.map((a) => a.profileId), ['claude']);
      expect(prefs.autoHostAcp, isEmpty);
      final again = UiPrefs.fromJson(prefs.toJson());
      expect(again.autoHostOpenCode?.binary, '/bin/opencode');
      final unnamed = UiPrefs.fromJson({
        'autoHostOpenCode': {'name': ''},
      });
      expect(unnamed.autoHostOpenCode, isNull);
    });

    test('restore once, never beside another host on OpenCode\'s default '
        'database', () {
      final prefs = UiPrefs.fromJson({
        'autoHostOpenCode': {'name': 'opencode'},
      });
      HostRestorePlan plan(
        List<AppServeStatus> local, {
        Set<String> attempted = const {},
        bool supported = true,
      }) => planHostRestore(
        prefs,
        local,
        codexAttempted: const {},
        acpAttempted: attempted,
        acpSupported: supported,
      );
      expect(plan(const []).opencode?.name, 'opencode');
      expect(plan(const [], attempted: {'opencode'}).opencode, isNull);
      expect(plan(const [], supported: false).opencode, isNull);
      expect(plan([FakeBridgeApi.openCodeHost('other')]).opencode, isNull);
      expect(
        plan([
          FakeBridgeApi.openCodeHost('other', separateHistory: true),
        ]).opencode?.name,
        'opencode',
      );
      expect(plan([_acp('opencode', 'claude')]).opencode, isNull);
    });
  });

  test('a permission option without a name reads as its kind', () {
    AgentPermissionOption option(String kind, [String name = '']) =>
        AgentPermissionOption(id: 'id-$kind', name: name, kind: kind);
    expect(option('allow_once').label(l10n), l10n.permissionAllowOnce);
    expect(option('allow_once', 'Yes').label(l10n), 'Yes');
    expect(option('future_kind').label(l10n), 'id-future_kind');
  });

  testWidgets('a multiple-choice question answers every chosen label', (
    t,
  ) async {
    Map<String, List<String>>? answered;
    const raw =
        '{"questions":[{"id":"q1","header":"Files","question":"Which?",'
        '"multiple":true,"isOther":true,'
        '"options":[{"label":"a.dart"},{"label":"b.dart"}]}]}';
    await t.pumpWidget(
      host(
        Scaffold(
          body: UserInputCard(
            prompt: const AppEvent(
              kind: 'item/tool/requestUserInput',
              raw: raw,
            ),
            onAnswer: (_, answers) async => answered = answers,
          ),
        ),
        FakeBridgeApi(),
        locale: const Locale('en'),
      ),
    );
    await t.tap(find.byKey(const Key('user-input-q1-a.dart')));
    await t.tap(find.byKey(const Key('user-input-q1-b.dart')));
    await t.tap(find.byKey(const Key('user-input-q1-Other…')));
    await t.pump();
    // "Other" without text answers nothing yet.
    final submit = find.byKey(const Key('user-input-submit'));
    expect(t.widget<FilledButton>(submit).onPressed, isNull);
    await t.enterText(find.byKey(const Key('user-input-q1-text')), 'c.dart');
    await t.pump();
    await t.tap(find.byKey(const Key('user-input-submit')));
    await t.pump();
    expect(answered, {
      'q1': ['a.dart', 'b.dart', 'c.dart'],
    });
  });

  testWidgets('cancelling a question answers it as rejected', (t) async {
    Map<String, List<String>>? answered;
    await t.pumpWidget(
      host(
        Scaffold(
          body: UserInputCard(
            prompt: const AppEvent(
              kind: 'item/tool/requestUserInput',
              raw:
                  '{"questions":[{"id":"q1","question":"Go?",'
                  '"options":[{"label":"Yes"}]}]}',
            ),
            onAnswer: (_, answers) async => answered = answers,
          ),
        ),
        FakeBridgeApi(),
        locale: const Locale('en'),
      ),
    );
    await t.tap(find.byKey(const Key('user-input-cancel')));
    await t.pump();
    expect(answered, isEmpty);
  });
}
