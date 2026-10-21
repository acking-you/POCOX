// A neutral ACP model catalog for previews: the shapes a multi-provider
// agent reports (`provider/model` ids, model ids that contain `/`, long
// names, several providers, an effort option and a mode option), with
// made-up provider and model names, so a preview never suggests that any
// real provider or model is supported.

import 'package:pocox/src/bridge_api.dart';

/// `(provider id, provider label, [(model id, model label)])`.
const _providers = [
  (
    'example',
    'Example AI',
    [
      ('swift-2', 'Swift 2'),
      ('steady-2', 'Steady 2'),
      ('deep-thinker-3', 'Deep Thinker 3'),
    ],
  ),
  (
    'router',
    'Sample Router',
    [
      ('example/swift-2', 'example/swift-2'),
      ('lab/coder-9', 'lab/coder-9'),
      (
        'lab/a-model-with-an-unusually-long-name-for-layout-checks',
        'lab/a-model-with-an-unusually-long-name-for-layout-checks',
      ),
      ('open/tiny-1', 'open/tiny-1'),
    ],
  ),
  ('local', 'Local Runner', [('mini-1', 'Mini 1'), ('mini-2', 'Mini 2')]),
];

/// The value the model option starts on: a slash-containing model id.
const previewCurrentModel = 'router/lab/coder-9';

/// The catalog's settings.
SessionSettings previewAgentSettings() {
  final settings = SessionSettings(
    configOptions: [
      SessionConfigOption(
        id: 'model',
        name: 'Model',
        category: 'model',
        currentValue: previewCurrentModel,
        values: [
          for (final (provider, label, models) in _providers)
            for (final (id, name) in models)
              SessionConfigValue(value: '$provider/$id', name: '$label/$name'),
        ],
      ),
      const SessionConfigOption(
        id: 'effort',
        name: 'Effort',
        category: 'thought_level',
        currentValue: 'high',
        values: [
          SessionConfigValue(value: 'low', name: 'Low'),
          SessionConfigValue(value: 'high', name: 'High'),
          SessionConfigValue(value: 'default', name: 'Default'),
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
  );
  assertCurrentValuesOffered(settings);
  return settings;
}

/// Every option's current value is exactly one of its offered values.
void assertCurrentValuesOffered(SessionSettings settings) {
  for (final option in settings.configOptions) {
    final matches = option.values.where((v) => v.value == option.currentValue);
    if (matches.length != 1) {
      throw StateError(
        'fixture option ${option.id}: current value '
        '${option.currentValue} is offered ${matches.length} times',
      );
    }
  }
}
