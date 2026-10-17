import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/hosting/claude_environment_section.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';
import 'package:pocket_codex/src/widgets/group_card.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// The model service being edited for one host: where it gets its model
/// (the agent's existing configuration, the official Codex account, or a
/// custom provider with its API type, base URL, key and default model).
///
/// Only what [support] lists can be chosen; it comes from the bridge, which
/// validates the same matrix again on save. A loaded source or custom
/// provider API the agent does not support stays visible as [incompatible]
/// (never silently replaced) until another one is chosen. The key is never read back: a stored one is
/// reported as set and kept unless replaced or removed.
class ModelServiceDraft extends ChangeNotifier {
  /// Creates an empty (inherited) draft.
  ModelServiceDraft() {
    environment.addListener(notifyListeners);
  }

  /// Claude behavior overrides for this same saved revision.
  final environment = ClaudeEnvironmentDraft();

  /// Custom provider base URL.
  final baseUrl = TextEditingController();

  /// A new key; blank keeps (or, for a new host, leaves out) the stored one.
  final key = TextEditingController();

  /// Custom provider default model.
  final model = TextEditingController();

  String _source = 'inherited';
  String? _protocol;
  bool _removeKey = false;
  HostConfig _saved = const HostConfig();
  HostConfigSupport _support = const HostConfigSupport();

  /// The selected source.
  String get source => _source;

  /// The selected custom provider API.
  String? get protocol => _protocol;

  /// Whether the stored key is to be removed.
  bool get removeKey => _removeKey;

  /// The configuration last loaded or saved.
  HostConfig get saved => _saved;

  /// What the engine can select.
  HostConfigSupport get support => _support;

  /// Select [source] (one of [support]'s).
  set source(String source) {
    if (!_support.sources.contains(source) || source == _source) return;
    _source = source;
    _protocol ??= _support.protocols.firstOrNull;
    notifyListeners();
  }

  /// Select the custom provider API (one of [support]'s).
  set protocol(String? protocol) {
    if (protocol == null || !_support.protocols.contains(protocol)) return;
    _protocol = protocol;
    notifyListeners();
  }

  /// Remove (or keep) the stored key.
  set removeKey(bool remove) {
    _removeKey = remove;
    if (remove) key.clear();
    notifyListeners();
  }

  /// A text field changed.
  void edited() => notifyListeners();

  /// Fill the fields from [config] (a load or a save).
  void load(HostConfig config) {
    _saved = config;
    environment.load(config.claudeEnv);
    _source = config.source;
    _protocol = config.protocol;
    baseUrl.text = config.baseUrl ?? '';
    model.text = config.model ?? '';
    key.clear();
    _removeKey = false;
    _clamp();
    notifyListeners();
  }

  /// Restrict the draft to what [support] allows (the agent changed).
  void restrict(HostConfigSupport support) {
    _support = support;
    environment.variables = support.claudeVariables;
    _clamp();
    notifyListeners();
  }

  // Only a default fills in: the saved custom API is kept even when this
  // agent cannot use it, so it is reported, not silently swapped.
  void _clamp() {
    if (_support.protocols.contains(_protocol) || _savedProtocolKept) return;
    _protocol = _support.protocols.firstOrNull;
  }

  bool get _savedProtocolKept =>
      _saved.source == 'custom' &&
      _protocol != null &&
      _protocol == _saved.protocol;

  /// The selected source, or the custom provider API, is one this agent
  /// cannot use (a configuration saved for another agent); it must be
  /// changed before saving.
  bool get incompatible =>
      !_support.sources.contains(_source) ||
      (_source == 'custom' && !_support.protocols.contains(_protocol));

  bool get _keyKept =>
      !_removeKey && _saved.keySet && _saved.source == 'custom';

  /// The save request for the current fields.
  HostConfigInput get input => HostConfigInput(
    claudeEnv: _support.claudeVariables.isEmpty ? const {} : environment.input,
    source: _source,
    protocol: _source == 'custom' ? _protocol : null,
    baseUrl: _source == 'custom' ? baseUrl.text.trim() : null,
    model: _source == 'custom' && model.text.trim().isNotEmpty
        ? model.text.trim()
        : null,
  );

  /// What a save does with the key. A new host ([fresh]) never inherits a
  /// key left by an earlier host of the same name: only a typed one is kept.
  /// Only a custom provider holds a key.
  HostKeyAction keyAction({required bool fresh}) {
    if (_source != 'custom' || _removeKey) return HostKeyAction.remove;
    if (typedKey != null) return HostKeyAction.replace;
    return fresh ? HostKeyAction.remove : HostKeyAction.keep;
  }

  /// The typed key, when one is sent (a custom provider only).
  String? get typedKey {
    final typed = key.text.trim();
    return _source != 'custom' || typed.isEmpty ? null : typed;
  }

  /// Why the draft cannot be saved, or null. A new host ([fresh]) never
  /// keeps a stored key.
  String? problem(AppLocalizations l10n, {bool fresh = false}) {
    if (incompatible) return l10n.hostSourceUnsupported;
    if (_support.claudeVariables.isNotEmpty && !environment.valid) {
      return l10n.claudeEnvRequired;
    }
    if (_source != 'custom') return null;
    if (baseUrl.text.trim().isEmpty) return l10n.hostBaseUrlRequired;
    if (_support.modelRequired && model.text.trim().isEmpty) {
      return l10n.hostModelRequired;
    }
    if (_support.keyRequired && typedKey == null && (fresh || !_keyKept)) {
      return l10n.hostKeyRequired;
    }
    return null;
  }

  /// Whether the fields differ from [saved].
  bool get dirty {
    final i = input;
    return !mapEquals(i.claudeEnv, _saved.claudeEnv) ||
        i.source != _saved.source ||
        (i.source == 'custom' &&
            (i.protocol != _saved.protocol ||
                i.baseUrl != (_saved.baseUrl ?? '') ||
                i.model != _saved.model)) ||
        key.text.trim().isNotEmpty ||
        _removeKey;
  }

  @override
  void dispose() {
    environment.removeListener(notifyListeners);
    environment.dispose();
    baseUrl.dispose();
    key.dispose();
    model.dispose();
    super.dispose();
  }
}

/// The name of a model service [source] (`official`, `custom`, else the
/// agent's existing configuration).
String modelSourceLabel(AppLocalizations l10n, String source) =>
    switch (source) {
      'official' => l10n.hostSourceOfficial,
      'custom' => l10n.hostSourceCustom,
      _ => l10n.hostSourceInherited,
    };

/// The "Model service" section of the hosting editor for [draft].
///
/// [inherited] describes what the existing configuration provides (it is
/// shown under that choice); [official] is the in-place sign-in, shown
/// under the official account choice.
class ModelServiceSection extends StatelessWidget {
  /// Creates the section.
  const ModelServiceSection({
    super.key,
    required this.draft,
    required this.inherited,
    this.official,
    this.enabled = true,
    this.footer,
    this.info,
  });

  /// The configuration being edited.
  final ModelServiceDraft draft;

  /// What the section is for, behind the title's info mark; the general
  /// explanation when null.
  final String? info;

  /// What the agent's existing configuration provides.
  final Widget inherited;

  /// The official sign-in, for native Codex.
  final Widget? official;

  /// Whether the fields can be edited.
  final bool enabled;

  /// Save / apply controls, at the end of the section.
  final Widget? footer;

  static String _protocolLabel(AppLocalizations l10n, String protocol) =>
      switch (protocol) {
        'anthropic-messages' => l10n.hostProtocolAnthropic,
        'chat-completions' => l10n.hostProtocolChat,
        _ => l10n.hostProtocolResponses,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: draft,
      builder: (context, _) => GroupCard(
        key: const Key('host-model-service'),
        title: l10n.hostSectionModel,
        info: info ?? l10n.hostSectionModelHint,
        children: [
          EditorBlock(child: _body(context, l10n)),
          if (draft.support.claudeVariables.isNotEmpty)
            EditorBlock(
              child: ClaudeEnvironmentSection(
                draft: draft.environment,
                enabled: enabled,
                customProvider: draft.source == 'custom',
              ),
            ),
          if (footer != null) EditorBlock(child: footer!),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final sources = draft.support.sources;
    // A single source is not a choice: only what it provides is shown.
    final choose = sources.length > 1 || draft.incompatible;
    final children = <Widget>[
      if (choose) ...[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final source in sources)
              ServiceChoice(
                key: Key('host-source-$source'),
                label: modelSourceLabel(l10n, source),
                selected: draft.source == source,
                onSelected: enabled ? () => draft.source = source : null,
              ),
          ],
        ),
        const SizedBox(height: 14),
      ],
    ];
    if (draft.incompatible) {
      children
        ..add(
          EditorNote(
            l10n.hostSourceUnsupported,
            key: const Key('host-source-incompatible'),
            color: scheme.error,
          ),
        )
        ..add(const SizedBox(height: 8));
    }
    switch (draft.source) {
      case 'official':
        if (official != null) children.add(official!);
      case 'custom':
        children.addAll(_custom(context, l10n, scheme));
      default:
        children.add(inherited);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  List<Widget> _custom(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    final protocols = draft.support.protocols;
    final keySet = draft.saved.keySet && draft.saved.source == 'custom';
    return [
      Text(
        l10n.hostProtocolLabel,
        style: Theme.of(context).textTheme.labelLarge,
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final protocol in protocols)
            ServiceChoice(
              key: Key('host-protocol-$protocol'),
              label: _protocolLabel(l10n, protocol),
              selected: draft.protocol == protocol,
              onSelected: enabled ? () => draft.protocol = protocol : null,
            ),
        ],
      ),
      const SizedBox(height: 14),
      TextField(
        key: const Key('host-base-url'),
        controller: draft.baseUrl,
        enabled: enabled,
        keyboardType: TextInputType.url,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: l10n.hostBaseUrl,
          hintText: draft.protocol == 'anthropic-messages'
              ? 'https://example.com'
              : 'https://example.com/v1',
        ),
        onChanged: (_) => draft.edited(),
      ),
      const SizedBox(height: 14),
      FocusHelp(
        help: keySet ? l10n.hostApiKeyStored : l10n.hostKeyEnvNote,
        child: TextField(
          key: const Key('host-api-key'),
          controller: draft.key,
          enabled: enabled && !draft.removeKey,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: l10n.hostApiKey),
          onChanged: (_) => draft.edited(),
        ),
      ),
      if (keySet)
        CheckboxListTile(
          key: const Key('host-api-key-remove'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          title: Text(l10n.hostApiKeyRemove),
          value: draft.removeKey,
          onChanged: enabled ? (v) => draft.removeKey = v ?? false : null,
        ),
      const SizedBox(height: 14),
      // The provider's model for new sessions; a conversation's own model
      // choice is made in the conversation and not stored here.
      FocusHelp(
        help: l10n.hostModelDefaultNote,
        child: TextField(
          key: const Key('host-model'),
          controller: draft.model,
          enabled: enabled,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: draft.support.modelRequired
                ? l10n.hostModelDefault
                : l10n.hostModelOptional,
          ),
          onChanged: (_) => draft.edited(),
        ),
      ),
      if (draft.problem(l10n) case final problem? when !draft.incompatible) ...[
        const SizedBox(height: 8),
        EditorNote(problem, color: cautionColor(scheme)),
      ],
    ];
  }
}

/// One model source or provider API choice: styled like the theme's choice
/// chips, but its label wraps instead of being cut, so a name such as
/// "OpenAI Chat Completions" stays whole on a narrow screen or under large
/// text. Disabled when [onSelected] is null.
class ServiceChoice extends StatelessWidget {
  /// Creates a choice.
  const ServiceChoice({
    super.key,
    required this.label,
    required this.selected,
    this.onSelected,
  });

  /// The full name of the choice.
  final String label;

  /// Whether this is the current choice.
  final bool selected;

  /// Chooses it; null disables the choice.
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final chip = theme.chipTheme;
    final enabled = onSelected != null;
    final shape =
        (chip.shape ??
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(kControlRadius),
                ))
            .copyWith(
              side: selected
                  ? BorderSide.none
                  : chip.side ?? BorderSide(color: scheme.outlineVariant),
            );
    var color = selected ? scheme.onTertiaryContainer : scheme.onSurface;
    if (!enabled) color = color.withValues(alpha: 0.38);
    final style = (chip.labelStyle ?? theme.textTheme.labelLarge)?.copyWith(
      color: color,
    );
    final padded = theme.materialTapTargetSize == MaterialTapTargetSize.padded;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      enabled: enabled,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: selected
            ? chip.selectedColor ?? scheme.secondaryContainer
            : Colors.transparent,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          mouseCursor: clickable,
          onTap: onSelected,
          customBorder: shape,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: padded ? kMinInteractiveDimension : 32,
              minWidth: padded ? kMinInteractiveDimension : 32,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selected) ...[
                    Icon(
                      AppIcons.check,
                      size: 18,
                      color: enabled ? chip.checkmarkColor ?? color : color,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(child: Text(label, style: style)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
