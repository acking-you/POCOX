import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/adaptive_sheet.dart';
import 'package:pocox/src/widgets/field_help.dart';

/// Session-only speech settings; an empty model preserves the host default.
class VoiceSettings {
  const VoiceSettings({this.model, this.voice});
  final String? model;
  final String? voice;
}

/// Realtime models offered when starting a call.
///
/// The app-server has no model catalogue for realtime (only voices), so this
/// is the list the protocol itself names for the version POCOX speaks
/// (V3, `gpt-live-1-codex` is its built-in default). "Host default" sends no
/// model and lets the host's `experimental_realtime_ws_model` decide; a custom
/// id stays available for a host configured with something else.
const voiceModels = <String>['gpt-live-1-codex'];

/// Sentinel for the "custom model id" entry in the model dropdown.
const _customModel = '__custom__';

/// Where a call goes.
enum VoiceTarget {
  /// Into the typed conversation on screen: the realtime session starts on
  /// its thread, takes its recent history as context, and hands work to it.
  here,

  /// Into a conversation of its own, made for talking.
  newConversation,
}

/// What the start sheet settled on.
class VoiceStart {
  /// Creates a choice.
  const VoiceStart({required this.target, required this.settings});

  /// Where the call goes.
  final VoiceTarget target;

  /// Its voice and model.
  final VoiceSettings settings;
}

/// Ask where and how to talk: a popover on desktop, a sheet on touch.
/// [canTalkHere] offers the conversation on screen; otherwise the call gets
/// a conversation of its own (or, in a voice conversation, starts again in
/// it).
Future<VoiceStart?> showVoiceStartSheet(
  BuildContext context, {
  required BridgeApi api,
  required String serviceKey,
  required bool canTalkHere,
}) => showAdaptivePanel<VoiceStart>(
  context: context,
  maxWidth: 440,
  // The sheet scrolls its options itself and keeps the start button in view.
  scrollable: false,
  builder: (_) => VoiceStartSheet(
    api: api,
    serviceKey: serviceKey,
    canTalkHere: canTalkHere,
  ),
);

/// Starting a call: where it goes (when there is a choice), the voice as
/// one-tap chips from the host's own catalog, the model behind "More
/// options", and one large start button. Loading the catalog is retryable,
/// since an unsupported or unreachable host says so here first.
class VoiceStartSheet extends StatefulWidget {
  /// Creates the sheet.
  const VoiceStartSheet({
    super.key,
    required this.api,
    required this.serviceKey,
    required this.canTalkHere,
  });

  /// The bridge.
  final BridgeApi api;

  /// The host's service.
  final String serviceKey;

  /// Whether the typed conversation on screen can take the call.
  final bool canTalkHere;

  @override
  State<VoiceStartSheet> createState() => _VoiceStartSheetState();
}

class _VoiceStartSheetState extends State<VoiceStartSheet> {
  final _model = TextEditingController();
  // Null = host default; [_customModel] = typed id in [_model].
  String? _modelChoice;
  List<String>? _voices;
  String? _voice;
  String? _error;
  bool _more = false;
  late VoiceTarget _target = widget.canTalkHere
      ? VoiceTarget.here
      : VoiceTarget.newConversation;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _voices = null;
      _error = null;
    });
    try {
      final raw = await widget.api.appRealtimeRequest(
        widget.serviceKey,
        'thread/realtime/listVoices',
        '{}',
      );
      final voices = (jsonDecode(raw) as Map)['voices'] as Map;
      // Upstream V3 uses the V1 voice catalog; V2 names are not interchangeable.
      final names = (voices['v1'] as List).cast<String>();
      if (names.isEmpty) {
        throw StateError('The host returned no compatible voices');
      }
      if (mounted) {
        setState(() {
          _voices = names;
          _voice = names.contains(voices['defaultV1'])
              ? voices['defaultV1'] as String
              : names.first;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _start() => Navigator.pop(
    context,
    VoiceStart(
      target: _target,
      settings: VoiceSettings(
        model: switch (_modelChoice) {
          _customModel => _model.text.trim(),
          final choice => choice,
        },
        voice: _voice,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final signal = signalColor(scheme);
    final heading = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
      color: scheme.onSurfaceVariant,
    );
    final start = FilledButton.icon(
      key: const Key('voice-start-confirm'),
      onPressed: _voices == null ? null : _start,
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 15),
      ),
      icon: const Icon(AppIcons.mic, size: 20),
      label: Text(l.voiceStartTalking),
    );
    // The options scroll; starting stays in reach below them.
    return Column(
      key: const Key('voice-start-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: signal.withValues(alpha: 0.14),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(AppIcons.graphic_eq, color: signal, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l.voiceLive, style: theme.textTheme.titleMedium),
                          // With a choice to make, the cards say what each does.
                          if (!widget.canTalkHere) ...[
                            const SizedBox(height: 2),
                            Text(l.voiceStartHint, style: helpTextStyle(theme)),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if (widget.canTalkHere) ...[
                  const SizedBox(height: 18),
                  _TargetCard(
                    key: const Key('voice-target-here'),
                    icon: AppIcons.chat_bubble_outline,
                    title: l.voiceHereTitle,
                    body: l.voiceHereBody,
                    selected: _target == VoiceTarget.here,
                    onTap: () => setState(() => _target = VoiceTarget.here),
                  ),
                  const SizedBox(height: 8),
                  _TargetCard(
                    key: const Key('voice-target-new'),
                    icon: AppIcons.graphic_eq,
                    title: l.voiceNewSession,
                    body: l.voiceNewBody,
                    selected: _target == VoiceTarget.newConversation,
                    onTap: () =>
                        setState(() => _target = VoiceTarget.newConversation),
                  ),
                ],
                const SizedBox(height: 18),
                Text(l.voiceVoice, style: heading),
                const SizedBox(height: 8),
                if (_error != null) ...[
                  Text(
                    l.voiceUnavailable,
                    style: TextStyle(color: scheme.error),
                  ),
                  const SizedBox(height: 2),
                  Text(_error!, style: helpTextStyle(theme)),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(onPressed: _load, child: Text(l.retry)),
                  ),
                ] else if (_voices == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: LinearProgressIndicator(),
                  )
                else
                  Wrap(
                    key: const Key('voice-voices'),
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final voice in _voices!)
                        ChoiceChip(
                          key: Key('voice-voice-$voice'),
                          label: Text(voice),
                          selected: voice == _voice,
                          onSelected: (_) => setState(() => _voice = voice),
                        ),
                    ],
                  ),
                const SizedBox(height: 10),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const Key('voice-more'),
                    onPressed: () => setState(() => _more = !_more),
                    icon: Icon(
                      _more ? AppIcons.expand_less : AppIcons.expand_more,
                      size: 18,
                    ),
                    label: Text(l.voiceMoreOptions),
                  ),
                ),
                Motion.resize(
                  context,
                  alignment: Alignment.topCenter,
                  child: !_more
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              DropdownButtonFormField<String?>(
                                key: const Key('voice-model'),
                                initialValue: _modelChoice,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  labelText: l.voiceModel,
                                ),
                                items: [
                                  DropdownMenuItem(
                                    child: Text(l.voiceModelDefault),
                                  ),
                                  for (final model in voiceModels)
                                    DropdownMenuItem(
                                      value: model,
                                      child: Text(
                                        model == 'gpt-live-1-codex'
                                            ? l.voiceModelFrameless
                                            : model,
                                      ),
                                    ),
                                  DropdownMenuItem(
                                    value: _customModel,
                                    child: Text(l.voiceModelCustom),
                                  ),
                                ],
                                onChanged: (value) =>
                                    setState(() => _modelChoice = value),
                              ),
                              if (_modelChoice == _customModel) ...[
                                const SizedBox(height: 8),
                                TextField(
                                  key: const Key('voice-model-custom'),
                                  controller: _model,
                                  autofocus: true,
                                  // Empty falls back to the host's model: the
                                  // placeholder says so; the length limit needs
                                  // no counter.
                                  decoration: InputDecoration(
                                    labelText: l.voiceModelCustomLabel,
                                    hintText: l.voiceModelHint,
                                    counterText: '',
                                  ),
                                  maxLength: 128,
                                ),
                              ],
                            ],
                          ),
                        ),
                ),
                const SizedBox(height: 8),
                Text(l.voiceTaskContinues, style: helpTextStyle(theme)),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: start,
        ),
      ],
    );
  }
}

/// One place a call can go, chosen like a radio button: the whole card
/// takes the tap and the chosen one carries the signal colour.
class _TargetCard extends StatelessWidget {
  const _TargetCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final signal = signalColor(scheme);
    return Semantics(
      selected: selected,
      button: true,
      child: AnimatedContainer(
        duration: Motion.of(context, Motion.fast),
        decoration: BoxDecoration(
          color: selected
              ? signal.withValues(alpha: 0.08)
              : scheme.onSurface.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? signal.withValues(alpha: 0.6)
                : scheme.outlineVariant.withValues(alpha: 0.6),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: selected ? signal : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(body, style: helpTextStyle(theme)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected
                      ? AppIcons.check_circle_rounded
                      : AppIcons.radio_button_unchecked,
                  size: 18,
                  color: selected ? signal : scheme.outlineVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
