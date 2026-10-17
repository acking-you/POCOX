/// What a model said instead of an ordinary answer: a failure (`modelError`)
/// or output it returned only as reasoning (`reasoningOutput`).
///
/// Both are facts from the host, rendered as such: a failure is never shown as
/// a reply, and reasoning-only output is shown in full but never labelled as an
/// answer or split by guessing where an answer might start.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/screens/app_session/activity_cards.dart'
    show MessageAction;
import 'package:pocket_codex/src/screens/app_session/message_actions.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';
import 'package:pocket_codex/src/widgets/markdown_view.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';

/// A `modelError` item's body (also a classified terminal `turn.error`):
/// `{code, statusCode?, retryable, model, provider, itemId, turnId}`.
class ModelFailure {
  const ModelFailure({
    required this.code,
    this.statusCode,
    this.retryable = false,
    this.model = '',
    this.provider = '',
    this.itemId = '',
    this.turnId = '',
  });

  /// Bounded failure class (`region_unavailable`, `rate_limited`, …).
  final String code;
  final int? statusCode;
  final bool retryable;
  final String model;
  final String provider;

  /// The host's `modelError` item ID (`#error:<assistant message ID>`).
  final String itemId;

  /// The exact prompt the failed message answered (a supplement's own ID,
  /// not necessarily the running turn's).
  final String turnId;

  /// Parses an item body or a terminal `turn.error`; unreadable is `unknown`.
  static ModelFailure parse(Object? raw) {
    Object? value = raw;
    if (raw is String) {
      try {
        value = jsonDecode(raw);
      } catch (_) {
        value = null;
      }
    }
    if (value is! Map) return const ModelFailure(code: 'unknown');
    final map = value;
    String str(String key) =>
        map[key] is String ? (map[key] as String).trim() : '';
    final status = map['statusCode'];
    return ModelFailure(
      code: str('code').isEmpty ? 'unknown' : str('code'),
      statusCode: status is int ? status : null,
      retryable: map['retryable'] == true,
      model: str('model'),
      provider: str('provider'),
      itemId: str('itemId'),
      turnId: str('turnId'),
    );
  }

  /// The item body this failure is carried as.
  String encode() => jsonEncode({
    'code': code,
    'statusCode': ?statusCode,
    'retryable': retryable,
    'model': model,
    'provider': provider,
    'itemId': itemId,
    'turnId': turnId,
  });

  /// `provider/model`, or whichever of them is known.
  String get modelLabel {
    if (model.isEmpty) return provider;
    if (provider.isEmpty || model.startsWith('$provider/')) return model;
    return '$provider/$model';
  }

  /// The localized reason, including what to do next.
  String reason(AppLocalizations l10n) => switch (code) {
    'region_unavailable' => l10n.modelErrorRegion,
    'authentication' => l10n.modelErrorAuthentication,
    'permission_denied' => l10n.modelErrorPermission,
    'model_unavailable' => l10n.modelErrorUnavailable,
    'rate_limited' => l10n.modelErrorRateLimited,
    'quota_exceeded' => l10n.modelErrorQuota,
    'context_length' => l10n.modelErrorContext,
    'output_length' => l10n.modelErrorOutput,
    'provider_unavailable' => l10n.modelErrorProvider,
    'invalid_request' => l10n.modelErrorInvalid,
    _ => l10n.modelErrorUnknown,
  };
}

/// What the conversation's current failure card offers.
class ModelErrorActions {
  const ModelErrorActions({
    this.onRetry,
    this.onChangeModel,
    this.saving = false,
    this.incomplete = false,
  });

  /// Re-sends the failed message; null while it cannot be sent again.
  final VoidCallback? onRetry;

  /// Opens the conversation's own model selection.
  final VoidCallback? onChangeModel;

  /// A model change is being saved: Retry waits for it.
  final bool saving;

  /// The failed message is not available here in full (truncated, missing
  /// attachments, not loaded), so it is not sent again as recorded.
  final bool incomplete;
}

/// A turn's model failure: a light inline card with the reason, the model that
/// failed and, for the conversation's current failure only, its [actions].
class ModelErrorCard extends StatelessWidget {
  const ModelErrorCard({super.key, required this.body, this.actions});

  /// The item's text (see [ModelFailure]).
  final String body;

  /// Null for a failure that is only history.
  final ModelErrorActions? actions;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failure = ModelFailure.parse(body);
    final muted = scheme.onSurfaceVariant;
    final details = [
      if (failure.modelLabel.isNotEmpty)
        l10n.modelErrorModel(failure.modelLabel),
      if (failure.statusCode != null)
        l10n.modelErrorStatus('${failure.statusCode}'),
    ].join(' · ');
    final actions = this.actions;
    final retry = actions != null && !actions.incomplete;
    final buttons = <Widget>[
      if (actions?.onChangeModel case final change?)
        TextButton.icon(
          key: const Key('model-error-change-model'),
          onPressed: change,
          icon: const Icon(AppIcons.auto_awesome, size: 16),
          label: Text(l10n.modelErrorChangeModel),
        ),
      if (retry)
        Tooltip(
          message: l10n.modelErrorRetryHint,
          child: TextButton.icon(
            key: const Key('model-error-retry'),
            onPressed: actions.saving ? null : actions.onRetry,
            icon: actions.saving
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : const Icon(AppIcons.refresh_rounded, size: 16),
            label: Text(l10n.modelErrorRetry),
          ),
        ),
    ];
    return Semantics(
      container: true,
      child: Container(
        key: const Key('model-error-card'),
        margin: const EdgeInsets.only(top: 10, bottom: 4),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(kPanelRadius),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                AppIcons.error_outline,
                size: 16,
                color: scheme.error,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.modelErrorTitle, style: theme.textTheme.labelLarge),
                  const SizedBox(height: 2),
                  Text(failure.reason(l10n), style: theme.textTheme.bodyMedium),
                  if (details.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      details,
                      key: const Key('model-error-details'),
                      style: helpTextStyle(theme).copyWith(color: muted),
                    ),
                  ],
                  if (actions?.incomplete ?? false) ...[
                    const SizedBox(height: 4),
                    Text(
                      l10n.modelErrorIncomplete,
                      key: const Key('model-error-incomplete'),
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                  // Below the text, so a phone's width keeps both actions
                  // full-size; they wrap rather than squeeze the reason.
                  if (buttons.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Wrap(spacing: 4, runSpacing: 0, children: buttons),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A completed answer the model returned only as reasoning: shown in full as
/// output, with a note that no separate answer came back.
class ReasoningOutputView extends StatelessWidget {
  const ReasoningOutputView({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final mobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final body = SizedBox(
      width: double.infinity,
      child: MarkdownView(data: text),
    );
    return Padding(
      key: const Key('reasoning-output'),
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppIcons.lightbulb_outline, size: 13, color: muted),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  l10n.reasoningOutputNote,
                  style: helpTextStyle(
                    Theme.of(context),
                  ).copyWith(color: muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (mobile && text.trim().isNotEmpty)
            MessageActions(text: text, isUser: false, child: body)
          else
            body,
          if (!mobile && text.trim().isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: MessageAction(
                icon: AppIcons.content_copy_outlined,
                tooltip: l10n.copy,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: text));
                  showToastOk(context, l10n.copied);
                },
              ),
            ),
        ],
      ),
    );
  }
}
