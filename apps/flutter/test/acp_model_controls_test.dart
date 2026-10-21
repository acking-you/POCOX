// ACP model / effort controls against option shapes a generic ACP agent
// may report: a `model` option whose
// values are `provider/model` (model ids may themselves contain `/`), an
// `effort` option (category `thought_level`) that exists only while the
// selected model has variants, and a `mode` option. Every change answers
// with the complete option set, which replaces the old one. Also: choosing
// options before the first prompt, on the session a new conversation opens
// by itself, without losing or sending the draft.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session/agent_session_options.dart';
import 'package:pocox/src/screens/app_session/option_picker.dart';
import 'package:pocox/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/screen_harness.dart';
import 'package:pocox/src/widgets/adaptive_sheet.dart';

const _acp = 'pcx:dev:acp:agent';

final _caps = negotiatedAcpCapabilities(
  providerName: 'Fixture Agent',
  profileId: 'fixture',
);

/// Models: provider id → [(model id, label, variants)]. OpenRouter-style ids
/// carry a slash inside the model id.
const _catalog = {
  'anthropic': [
    ('claude-sonnet-4-5', 'Claude Sonnet 4.5', ['low', 'high']),
    ('claude-haiku-4-5', 'Claude Haiku 4.5', <String>[]),
  ],
  'openrouter': [
    ('openai/gpt-5', 'GPT-5', ['minimal', 'low', 'medium', 'high']),
    ('meta-llama/llama-4', 'Llama 4', <String>[]),
  ],
};

/// The options the agent reports for [model] (and [effort]).
SessionSettings _agentOptions(String model, {String? effort}) {
  final values = <SessionConfigValue>[
    for (final MapEntry(key: provider, value: models) in _catalog.entries)
      for (final (id, name, _) in models)
        SessionConfigValue(value: '$provider/$id', name: '$provider/$name'),
  ];
  final variants = [
    for (final MapEntry(key: provider, value: models) in _catalog.entries)
      for (final (id, _, v) in models)
        if ('$provider/$id' == model) ...v,
  ];
  return SessionSettings(
    configOptions: [
      SessionConfigOption(
        id: 'model',
        name: 'Model',
        category: 'model',
        currentValue: model,
        values: values,
      ),
      if (variants.isNotEmpty)
        SessionConfigOption(
          id: 'effort',
          name: 'Effort',
          category: 'thought_level',
          description: 'Available effort levels for this model',
          // An unset or vanished variant falls back to `default`.
          currentValue: effort != null && variants.contains(effort)
              ? effort
              : 'default',
          values: [
            for (final v in {...variants, 'default'})
              SessionConfigValue(value: v, name: v),
          ],
        ),
      const SessionConfigOption(
        id: 'mode',
        name: 'Session Mode',
        category: 'mode',
        currentValue: 'build',
        values: [
          SessionConfigValue(value: 'build', name: 'build'),
          SessionConfigValue(value: 'plan', name: 'plan'),
        ],
      ),
    ],
    // Legacy modes an ACP client that reads config options must ignore.
    currentMode: 'build',
    modes: const [
      SessionMode(id: 'build', name: 'build'),
      SessionMode(id: 'plan', name: 'plan'),
    ],
  );
}

/// A fake that answers changes the way an ACP agent's `setSessionConfigOption`
/// does: a model change recomputes the effort option; an effort change keeps
/// the model.
FakeBridgeApi _api(String model, {String? effort, String thread = 'ses-1'}) {
  final api = FakeBridgeApi()..acpCapabilities[_acp] = _caps;
  api.sessionSettings['$_acp|$thread'] = _agentOptions(model, effort: effort);
  api.onSessionConfig = (id, value, current) {
    final model = current?.configOptions
        .firstWhere((o) => o.id == 'model')
        .currentValue;
    final effort = current?.configOptions
        .where((o) => o.id == 'effort')
        .firstOrNull
        ?.currentValue;
    return switch (id) {
      'model' => _agentOptions(value, effort: effort),
      'effort' => _agentOptions(model!, effort: value),
      _ => current,
    };
  };
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
}) async {
  t.view.physicalSize = const Size(1400, 900);
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

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  group('option ordering and filtering', () {
    test('model, then effort, then mode, whatever order the agent used', () {
      final options = _agentOptions(
        'anthropic/claude-sonnet-4-5',
      ).configOptions;
      final reversed = orderedOptions(options.reversed.toList());
      expect(reversed.map((o) => o.id), ['model', 'effort', 'mode']);
    });

    test('a mode config option hides legacy modes; without one they show', () {
      expect(
        showsLegacyModes(_agentOptions('anthropic/claude-haiku-4-5')),
        isFalse,
      );
      expect(
        showsLegacyModes(
          const SessionSettings(
            modes: [SessionMode(id: 'a', name: 'A')],
          ),
        ),
        isTrue,
      );
    });

    test('search matches labels, groups and slash-containing ids verbatim', () {
      final values = _agentOptions(
        'anthropic/claude-haiku-4-5',
      ).configOptions.first.values;
      expect(filterOptionValues(values, 'openai/gpt').map((v) => v.value), [
        'openrouter/openai/gpt-5',
      ]);
      expect(filterOptionValues(values, 'LLAMA').map((v) => v.value), [
        'openrouter/meta-llama/llama-4',
      ]);
      expect(filterOptionValues(values, '  ').length, values.length);
      const grouped = SessionConfigValue(
        value: 'x',
        name: 'Model X',
        group: 'Vendor',
      );
      expect(filterOptionValues(const [grouped], 'vendor'), [grouped]);
      expect(optionValueLabel(grouped), 'Vendor · Model X');
    });
  });

  testWidgets('a model change replaces the whole option set: effort appears, '
      'resets to default, and disappears with the model', (t) async {
    final api = _api('anthropic/claude-haiku-4-5');
    await _open(t, api, thread: 'ses-1');
    // Haiku has no variants: no effort control at all.
    expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
    expect(find.byKey(const Key('agent-config-effort')), findsNothing);
    expect(find.byKey(const Key('agent-config-mode')), findsOneWidget);
    // The legacy mode list is ignored next to a mode option.
    expect(find.byKey(const Key('agent-mode')), findsNothing);

    await _pickFromSearchOrMenu(t, 'model', 'openrouter/openai/gpt-5');
    expect(api.sessionConfigCalls.last, (
      'ses-1',
      'model',
      'openrouter/openai/gpt-5',
    ));
    await _frames(t);
    // The slash-containing id is sent verbatim and becomes the agent's
    // current value; the chip carries the full label in semantics and
    // tooltip, and its visible text ends with the model (a narrow chip may
    // drop the start, never the model).
    final model = api.sessionSettings['$_acp|ses-1']!.configOptions.firstWhere(
      (o) => o.id == 'model',
    );
    expect(model.currentValue, 'openrouter/openai/gpt-5');
    _expectChipLabel(t, 'model', 'Model', 'openrouter/GPT-5', tail: 'GPT-5');
    expect(find.byKey(const Key('agent-config-effort')), findsOneWidget);
    expect(find.text('default'), findsOneWidget);

    await _pickFromSearchOrMenu(t, 'effort', 'high');
    await _frames(t);
    expect(api.sessionConfigCalls.last, ('ses-1', 'effort', 'high'));
    expect(find.text('high'), findsOneWidget);

    // Back to a model without variants: the effort option is gone.
    await _pickFromSearchOrMenu(t, 'model', 'openrouter/meta-llama/llama-4');
    await _frames(t);
    expect(find.byKey(const Key('agent-config-effort')), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('an effort the new model lacks falls back to default', (t) async {
    final api = _api('openrouter/openai/gpt-5', effort: 'minimal');
    await _open(t, api, thread: 'ses-1');
    expect(find.text('minimal'), findsOneWidget);
    await _pickFromSearchOrMenu(t, 'model', 'anthropic/claude-sonnet-4-5');
    await _frames(t);
    expect(find.text('minimal'), findsNothing);
    expect(find.text('default'), findsOneWidget);
  });

  testWidgets('a long catalog opens a searchable list', (t) async {
    final api = FakeBridgeApi()..acpCapabilities[_acp] = _caps;
    api.sessionSettings['$_acp|ses-1'] = SessionSettings(
      configOptions: [
        SessionConfigOption(
          id: 'model',
          name: 'Model',
          category: 'model',
          currentValue: 'p/m0',
          values: [
            for (var i = 0; i < 40; i++)
              SessionConfigValue(
                value: 'p/m$i',
                name: 'Model $i',
                group: i.isEven ? 'Even' : 'Odd',
              ),
          ],
        ),
      ],
    );
    await _open(t, api, thread: 'ses-1');
    await t.tap(find.byKey(const Key('agent-config-model')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('agent-option-search')), findsOneWidget);
    await t.enterText(find.byKey(const Key('agent-option-search')), 'model 37');
    await t.pumpAndSettle();
    expect(find.byKey(const Key('agent-option-value-p/m37')), findsOneWidget);
    expect(find.byKey(const Key('agent-option-value-p/m2')), findsNothing);
    await t.enterText(find.byKey(const Key('agent-option-search')), 'zzz');
    await t.pumpAndSettle();
    expect(find.byKey(const Key('agent-option-no-match')), findsOneWidget);
    await t.enterText(find.byKey(const Key('agent-option-search')), 'm37');
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('agent-option-value-p/m37')));
    await t.pumpAndSettle();
    expect(api.sessionConfigCalls.single, ('ses-1', 'model', 'p/m37'));
  });

  testWidgets('a truncated value keeps its full label for assistive tech', (
    t,
  ) async {
    final api = FakeBridgeApi()..acpCapabilities[_acp] = _caps;
    const long =
        'provider/An extremely long model name that cannot fit in a chip';
    api.sessionSettings['$_acp|ses-1'] = const SessionSettings(
      configOptions: [
        SessionConfigOption(
          id: 'model',
          name: 'Model',
          category: 'model',
          currentValue: 'x',
          values: [SessionConfigValue(value: 'x', name: long, group: 'G')],
        ),
      ],
    );
    await _open(t, api, thread: 'ses-1');
    expect(find.bySemanticsLabel('Model: G · $long'), findsOneWidget);
  });

  testWidgets('a refused change keeps the agent value and reports it', (
    t,
  ) async {
    final api = _api('openrouter/openai/gpt-5', effort: 'low');
    await _open(t, api, thread: 'ses-1');
    api.sessionConfigError = StateError('Effort not found');
    final gate = Completer<void>();
    api.sessionConfigGate = gate;
    await t.tap(find.byKey(const Key('agent-config-effort')));
    await t.pumpAndSettle();
    final high = _menuItem('high');
    expect(high, findsOneWidget);
    await t.ensureVisible(high);
    await t.pumpAndSettle();
    await t.tap(high);
    await t.pump();
    expect(api.sessionConfigCalls.single, ('ses-1', 'effort', 'high'));
    // In flight: the chip shows progress.
    expect(
      find.descendant(
        of: find.byKey(const Key('agent-config-effort')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    gate.complete();
    await _frames(t);
    expect(find.textContaining('Effort not found'), findsWidgets);
    expect(find.text('low'), findsOneWidget);
  });

  testWidgets('an agent without variants or modes shows only its model', (
    t,
  ) async {
    final api = FakeBridgeApi()..acpCapabilities[_acp] = _caps;
    api.sessionSettings['$_acp|ses-1'] = const SessionSettings(
      configOptions: [
        SessionConfigOption(
          id: 'model',
          name: 'Model',
          category: 'model',
          currentValue: 'only',
          values: [SessionConfigValue(value: 'only', name: 'Only model')],
        ),
      ],
    );
    await _open(t, api, thread: 'ses-1');
    expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
    expect(find.byKey(const Key('agent-config-effort')), findsNothing);
    expect(find.byKey(const Key('agent-mode')), findsNothing);
  });

  group('before the first prompt', () {
    // Opening races, failures and disposal: acp_agent_welcome_test.dart.
    testWidgets('a new conversation opens its session by itself: options are '
        'choosable, nothing is sent, and the first send uses that session', (
      t,
    ) async {
      final api = _api('anthropic/claude-haiku-4-5', thread: 'unused')
        ..newSessionSettings = _agentOptions('anthropic/claude-haiku-4-5');
      await _open(t, api, cwd: '/work/alpha');
      // No setup step: the session is open and its options are real.
      expect(api.threadStartCalls, [_acp]);
      expect(api.lastCwd, '/work/alpha');
      expect(api.turnStartCount, 0);
      expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
      await t.enterText(find.byKey(const Key('composer-input')), 'my draft');
      await t.pump();
      await _pickFromSearchOrMenu(t, 'model', 'openrouter/openai/gpt-5');
      final prepared = api.sessionConfigCalls.single.$1;
      expect(find.text('my draft'), findsOneWidget);
      expect(api.turnStartCount, 0, reason: 'choosing sends nothing');
      await t.tap(find.byKey(const Key('send-btn')));
      await _frames(t);
      // One session: the send reuses the one opened ahead.
      expect(api.threadStartCalls, hasLength(1));
      expect(api.lastTurnThread, prepared);
      expect(api.lastTurnText, 'my draft');
    });

    testWidgets('no session is opened ahead for agents without per-session '
        'options', (t) async {
      final api = FakeBridgeApi()
        ..acpCapabilities[_acp] = const AppCapabilities(
          provider: 'acp',
          fast: false,
          permissionPresets: false,
          guardian: false,
          rateLimits: false,
          takeover: false,
          externalWriterMonitor: false,
          localSessions: false,
          planMode: false,
          protocol: 'acp',
        );
      await _open(t, api, cwd: '/work/alpha');
      // Its session opens with the first message, as before.
      expect(api.threadStartCalls, isEmpty);
      expect(find.byKey(const Key('agent-session-opening')), findsNothing);
      expect(find.byKey(const Key('agent-session-options')), findsNothing);
    });

    // UI-only: the catalog below stands in for a large agent-reported model
    // list (a gateway's models). Effort comes only from the agent's own
    // per-model option, as on the wire.
    group('a large agent-reported model catalog (fake bridge)', () {
      testWidgets(
        'every reported model is searchable and selectable; effort follows the '
        'agent-reported option of the selected model',
        (t) async {
          const gatewayModels = [
            (
              'gw/model-a',
              'Gateway · Model A',
              ['low', 'medium', 'high', 'max'],
            ),
            ('gw/model-b', 'Gateway · Model B', <String>[]),
            ('gw/model-c', 'Gateway · Model C', ['low', 'high']),
            ('gw/model-d', 'Gateway · Model D', ['low', 'medium', 'high']),
            ('gw/model-e', 'Gateway · Model E', <String>[]),
          ];

          SessionSettings buildGatewaySettings(
            String currentModel, {
            String? effort,
          }) {
            final modelValues = [
              for (final (id, name, _) in gatewayModels)
                SessionConfigValue(value: id, name: name, group: 'Gateway'),
            ];
            final variants = [
              for (final (id, _, v) in gatewayModels)
                if (id == currentModel) ...v,
            ];
            return SessionSettings(
              configOptions: [
                SessionConfigOption(
                  id: 'model',
                  name: 'Model',
                  category: 'model',
                  currentValue: currentModel,
                  values: modelValues,
                ),
                if (variants.isNotEmpty)
                  SessionConfigOption(
                    id: 'effort',
                    name: 'Effort',
                    category: 'thought_level',
                    currentValue: effort != null && variants.contains(effort)
                        ? effort
                        : 'default',
                    values: [
                      for (final v in {...variants, 'default'})
                        SessionConfigValue(value: v, name: v),
                    ],
                  ),
                const SessionConfigOption(
                  id: 'mode',
                  name: 'Session Mode',
                  category: 'mode',
                  currentValue: 'build',
                  values: [SessionConfigValue(value: 'build', name: 'build')],
                ),
              ],
            );
          }

          final api = FakeBridgeApi()..acpCapabilities[_acp] = _caps;
          api.sessionSettings['$_acp|ses-1'] = buildGatewaySettings(
            'gw/model-a',
          );
          api.onSessionConfig = (id, value, current) {
            final model = current?.configOptions
                .firstWhere((o) => o.id == 'model')
                .currentValue;
            final effort = current?.configOptions
                .where((o) => o.id == 'effort')
                .firstOrNull
                ?.currentValue;
            return switch (id) {
              'model' => buildGatewaySettings(value, effort: effort),
              'effort' => buildGatewaySettings(model!, effort: value),
              _ => current,
            };
          };

          await _open(t, api, thread: 'ses-1');

          // Initial model has effort variants.
          expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
          expect(find.byKey(const Key('agent-config-effort')), findsOneWidget);

          // Switch to a model without variants.
          await _pickFromSearchOrMenu(t, 'model', 'gw/model-b');
          await _frames(t);
          expect(api.sessionConfigCalls.last, ('ses-1', 'model', 'gw/model-b'));
          expect(find.byKey(const Key('agent-config-effort')), findsNothing);

          // Switch to a model with variants: the effort option reappears.
          await _pickFromSearchOrMenu(t, 'model', 'gw/model-c');
          await _frames(t);
          expect(api.sessionConfigCalls.last, ('ses-1', 'model', 'gw/model-c'));
          expect(find.byKey(const Key('agent-config-effort')), findsOneWidget);

          // Select high effort.
          await _pickFromSearchOrMenu(t, 'effort', 'high');
          await _frames(t);
          expect(api.sessionConfigCalls.last, ('ses-1', 'effort', 'high'));
          expect(find.text('high'), findsOneWidget);
        },
      );

      testWidgets(
        'a failed option change keeps the reported catalog and current model',
        (t) async {
          final api = _api('anthropic/claude-sonnet-4-5', effort: 'high');
          await _open(t, api, thread: 'ses-1');
          final before = api.sessionSettings['$_acp|ses-1']!;
          List<String> reported(String id) => [
            for (final v
                in before.configOptions.firstWhere((o) => o.id == id).values)
              v.value,
          ];
          _expectChipLabel(
            t,
            'model',
            'Model',
            'anthropic/Claude Sonnet 4.5',
            tail: 'Sonnet 4.5',
          );
          _expectChipLabel(t, 'effort', 'Effort', 'high', tail: 'high');

          api.sessionConfigError = StateError('agent refused the model');
          await t.tap(find.byKey(const Key('agent-config-model')));
          await t.pumpAndSettle();
          expect(_openMenu(t).values, unorderedEquals(reported('model')));
          await t.tap(_menuItem('anthropic/claude-haiku-4-5'));
          await t.pumpAndSettle();

          // The change was asked for and refused: the reason is shown, and
          // the model, its effort and every offered value stay as reported.
          expect(api.sessionConfigCalls.last, (
            'ses-1',
            'model',
            'anthropic/claude-haiku-4-5',
          ));
          expect(find.textContaining('agent refused the model'), findsWidgets);
          _expectChipLabel(
            t,
            'model',
            'Model',
            'anthropic/Claude Sonnet 4.5',
            tail: 'Sonnet 4.5',
          );
          _expectChipLabel(t, 'effort', 'Effort', 'high', tail: 'high');

          await t.tap(find.byKey(const Key('agent-config-model')));
          await t.pumpAndSettle();
          final model = _openMenu(t);
          expect(model.values, unorderedEquals(reported('model')));
          expect(model.checked, ['anthropic/claude-sonnet-4-5']);
          await _closeMenu(t);

          await t.tap(find.byKey(const Key('agent-config-effort')));
          await t.pumpAndSettle();
          final effort = _openMenu(t);
          expect(effort.values, unorderedEquals(reported('effort')));
          expect(effort.checked, ['high']);
          await _closeMenu(t);
          expect(
            api.sessionConfigCalls,
            hasLength(1),
            reason: 'only the refusal',
          );
          expect(t.takeException(), isNull);
        },
      );

      testWidgets(
        'switching conversation in place shows only the new session catalog',
        (t) async {
          final api = _api('anthropic/claude-sonnet-4-5');
          // A second session with a different catalog and no effort option.
          const other = SessionSettings(
            configOptions: [
              SessionConfigOption(
                id: 'model',
                name: 'Model',
                category: 'model',
                currentValue: 'gw/model-y',
                values: [
                  SessionConfigValue(value: 'gw/model-x', name: 'gw/Model X'),
                  SessionConfigValue(value: 'gw/model-y', name: 'gw/Model Y'),
                ],
              ),
            ],
          );
          api.sessionSettings['$_acp|ses-2'] = other;
          api.appThreads.addAll(const [
            ThreadMeta(id: 'ses-1', preview: 'one', cwd: '/w', updatedAt: 2),
            ThreadMeta(id: 'ses-2', preview: 'two', cwd: '/w', updatedAt: 1),
          ]);
          await _open(t, api, thread: 'ses-1');
          expect(find.byKey(const Key('agent-config-effort')), findsOneWidget);

          // Open ses-2 from the sidebar (same screen state); hold its
          // reopen so the in-between state is observable.
          final resume = Completer<void>();
          api.pendingResumes['ses-2'] = [resume.future];
          final tile = find.byKey(const Key('conv-tile-ses-2'));
          await t.ensureVisible(tile);
          await t.tap(tile);
          await _frames(t);
          expect(
            find.byKey(const Key('agent-config-effort')),
            findsNothing,
            reason: 'ses-1 options are gone before ses-2 reopened',
          );
          expect(
            find.byKey(const Key('agent-config-model')),
            findsNothing,
            reason: 'the ses-1 model cannot be changed while ses-2 reopens',
          );
          expect(api.sessionConfigCalls, isEmpty);

          resume.complete();
          await _frames(t);
          expect(find.byKey(const Key('agent-config-effort')), findsNothing);
          _expectChipLabel(t, 'model', 'Model', 'gw/Model Y', tail: 'Model Y');
          await t.tap(find.byKey(const Key('agent-config-model')));
          await t.pumpAndSettle();
          expect(
            t
                .widgetList<ChoiceRow<String>>(find.byType(ChoiceRow<String>))
                .map((item) => item.value),
            unorderedEquals(['gw/model-x', 'gw/model-y']),
          );
          await t.tap(_menuItem('gw/model-x'));
          await t.pumpAndSettle();
          expect(api.sessionConfigCalls.last, ('ses-2', 'model', 'gw/model-x'));
          expect(
            api
                .sessionSettings['$_acp|ses-1']!
                .configOptions
                .first
                .currentValue,
            'anthropic/claude-sonnet-4-5',
            reason: 'ses-1 is untouched',
          );
        },
      );
    });
  });
}

/// The values the open menu offers, and those it shows checked.
({List<String> values, List<String> checked}) _openMenu(WidgetTester t) {
  final items = t.widgetList<ChoiceRow<String>>(find.byType(ChoiceRow<String>));
  return (
    values: [for (final item in items) item.value!],
    checked: [
      for (final item in items)
        if (item.checked) item.value!,
    ],
  );
}

/// Dismiss the open menu without choosing.
Future<void> _closeMenu(WidgetTester t) async {
  Navigator.of(t.element(find.byType(ChoiceRow<String>).first)).pop();
  await t.pumpAndSettle();
  expect(find.byType(ChoiceRow<String>), findsNothing);
}

/// The open menu's item for [value].
Finder _menuItem(String value) =>
    find.byWidgetPredicate((w) => w is ChoiceRow<String> && w.value == value);

/// The chip of [option] announces and shows `title: full`, and its visible
/// text, whatever the font, keeps [tail]: either the whole label or "…" and
/// an end of it that includes [tail].
void _expectChipLabel(
  WidgetTester t,
  String option,
  String title,
  String full, {
  required String tail,
}) {
  final chip = find.byKey(Key('agent-config-$option'));
  expect(find.bySemanticsLabel('$title: $full'), findsOneWidget);
  final tooltip = t.widget<Tooltip>(
    find.descendant(of: chip, matching: find.byType(Tooltip)),
  );
  expect(tooltip.message, startsWith('$title: $full'));
  final shown = t
      .widget<Text>(
        find.descendant(
          of: find.descendant(
            of: chip,
            matching: find.byType(TailEllipsisText),
          ),
          matching: find.byType(Text),
        ),
      )
      .data!;
  expect(
    shown == full ||
        (shown.startsWith('…') && full.endsWith(shown.substring(1))),
    isTrue,
    reason: '"$shown" is the label or its end',
  );
  expect(shown, endsWith(tail));
}

/// Choose [value] of [option]: through the searchable list when the chip
/// opens one, otherwise through its menu.
Future<void> _pickFromSearchOrMenu(
  WidgetTester t,
  String option,
  String value,
) async {
  await t.tap(find.byKey(Key('agent-config-$option')));
  await t.pumpAndSettle();
  final listed = find.byKey(Key('agent-option-value-$value'));
  final target = listed.evaluate().isNotEmpty ? listed : _menuItem(value);
  expect(target, findsOneWidget);
  await t.ensureVisible(target);
  await t.pumpAndSettle();
  await t.tap(target);
  await t.pumpAndSettle();
}
