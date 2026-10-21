import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/error_format.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/hosting/host_picker.dart';
import 'package:pocox/src/hosting/official_login_panel.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/action_row.dart';
import 'package:pocox/src/widgets/code_row.dart';
import 'package:pocox/src/widgets/group_card.dart';
import 'package:pocox/src/widgets/icon_badge.dart';
import 'package:pocox/src/widgets/links.dart';
import 'package:pocox/src/widgets/status_dots.dart';
import 'package:pocox/src/widgets/utility_page.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/widgets/field_help.dart';

/// The way codex is set up to reach a model. Both live in the same
/// `CODEX_HOME`, and a selected custom provider wins over a stored
/// credential, so at most one is ever "in use".
enum _Method {
  /// ChatGPT OAuth, driven on a private local app-server; codex writes
  /// `auth.json`.
  chatgpt,

  /// A custom provider. Set per host in the hosting editor; this page only
  /// reports one that codex's own `config.toml` already selects.
  provider,
}

/// First-run configuration for external Codex.
///
/// Scope: this page sets up Codex itself (its `CODEX_HOME`), which hosts on
/// "Existing configuration" use. A host's own custom provider or official
/// account is chosen in the hosting editor ([configureHosting]); this page
/// writes no provider.
///
/// With neither a credential (`auth.json`) nor a selected custom provider,
/// codex cannot call a model. The page answers where codex stands, then lists
/// both ways in one card, each with its own control at the end of its row:
///
/// 1. ChatGPT sign-in, driven by `account/login/start` on a local app-server;
///    codex writes `auth.json` itself.
/// 2. A custom provider: per host, so the row opens the hosting editor, and
///    says so when codex's own `config.toml` already selects one.
///
/// The method codex runs on carries an "in use" mark. The Advanced card holds
/// the system prompt switch (openai/codex#30364): how codex prompts the
/// model, not how it gets access.
class CodexSetupScreen extends ConsumerStatefulWidget {
  /// Default constructor.
  const CodexSetupScreen({super.key});

  @override
  ConsumerState<CodexSetupScreen> createState() => _CodexSetupScreenState();
}

class _CodexSetupScreenState extends ConsumerState<CodexSetupScreen> {
  CodexSetupStatus? _status;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  /// The method codex is actually set up with, or null when neither is (or
  /// its configuration cannot be read).
  _Method? get _liveMethod {
    final status = _status;
    if (status == null) return null;
    // The bridge reports what codex will actually use: a selected custom
    // provider wins over a stored credential. An older bridge leaves it
    // empty, and the credential is taken first as before.
    switch (status.effectiveSource) {
      case 'custom':
        return _Method.provider;
      case 'account':
        return _Method.chatgpt;
      case 'none' || 'invalid':
        return null;
    }
    if (status.hasAuth) return _Method.chatgpt;
    if (status.hasCustomProvider) return _Method.provider;
    return null;
  }

  BridgeApi get _api => ref.read(bridgeApiProvider);

  Future<void> _loadStatus() async {
    if (!isDesktop) return;
    try {
      final s = await _api.codexSetupStatus();
      if (mounted) {
        setState(() => _status = s);
        // Keep the chat's "codex needs setup" banner/send-guard in sync with
        // what changed here or in the hosting editor (signed in, …).
        ref.invalidate(codexSetupStatusProvider);
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _run(Future<void> Function() op) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await op();
      await _loadStatus();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Open the hosting editor for a host the user picks, then re-read what
  /// codex's own setup says (the editor may have signed it in).
  Future<void> _configureHost() async {
    await configureHosting(context, ref);
    if (mounted) await _loadStatus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final status = _status;
    final nonDegraded = status?.promptVariant == 'non_degraded';
    final live = _liveMethod;
    return UtilityPage(
      route: '/settings',
      title: l10n.codexSetup,
      parent: UtilityParent(title: l10n.settingsTitle, route: '/settings'),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            // Matches the settings page this is pushed from, so the two read as
            // one column rather than two different page widths.
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
              children: [
                if (status != null) _statusCard(l10n, theme, status),
                const SizedBox(height: 10),
                GroupCard(
                  title: l10n.codexSetupMethodsTitle,
                  // What this page configures versus a host's own editor,
                  // which method wins, and where a sign-in's proxy is set.
                  info:
                      '${l10n.codexSetupProviderScope}\n\n'
                      '${l10n.codexSetupMethodsHint}\n\n'
                      '${l10n.codexSetupProxyNote}',
                  children: [
                    _MethodRow(
                      rowKey: const Key('codex-method-chatgpt'),
                      icon: AppIcons.chat_bubble_outline,
                      live: live == _Method.chatgpt,
                      body: _chatgptBody(l10n, live == _Method.chatgpt),
                    ),
                    _MethodRow(
                      rowKey: const Key('codex-method-provider'),
                      icon: AppIcons.bolt_outlined,
                      live: live == _Method.provider,
                      body: _providerBody(l10n, live == _Method.provider),
                    ),
                  ],
                ),
                if (isDesktop) ...[
                  const SizedBox(height: 10),
                  GroupCard(
                    title: l10n.codexSetupAdvanced,
                    children: [_nonDegradedRow(l10n, theme, nonDegraded)],
                  ),
                ],
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: _ErrorNotice(error),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The ChatGPT sign-in. Its sign-in or sign-out control sits at the end
  /// of the row and a sign-in's progress appears under it; both run on a
  /// private local Codex, so a phone, which has none, says where to sign in.
  Widget _chatgptBody(AppLocalizations l10n, bool inUse) {
    if (!isDesktop) {
      return _MethodText(
        title: l10n.codexSetupLoginSection,
        description: l10n.codexSetupLoginDesc,
        inUse: inUse,
        notes: [
          _InlineHint(
            key: const Key('codex-login-desktop-only'),
            text: l10n.codexSetupLoginDesktopOnly,
          ),
        ],
      );
    }
    return OfficialLoginPanel(
      status: _status,
      enabled: !_busy,
      onChanged: _loadStatus,
      header: _MethodText(
        title: l10n.codexSetupLoginSection,
        description: l10n.codexSetupLoginDesc,
        inUse: inUse,
      ),
    );
  }

  /// Where a custom provider is set now: per host, in the hosting editor,
  /// which the row's button opens. A provider codex's own configuration
  /// already selects is reported, not edited here; hosts on "Existing
  /// configuration" keep using it.
  Widget _providerBody(AppLocalizations l10n, bool inUse) {
    final text = _MethodText(
      title: l10n.codexSetupProviderSection,
      description: l10n.codexSetupProviderPerHost,
      inUse: inUse,
      notes: [
        if (_status?.hasCustomProvider ?? false)
          _InlineHint(
            key: const Key('codex-global-provider'),
            text: l10n.codexSetupGlobalProvider,
          ),
        if (!isDesktop)
          _InlineHint(
            key: const Key('codex-provider-desktop-only'),
            text: l10n.codexSetupHostingDesktopOnly,
          ),
      ],
    );
    if (!isDesktop) return text;
    return ActionRow(
      lead: text,
      action: OutlinedButton(
        key: const Key('codex-provider-hosts'),
        onPressed: _busy ? null : _configureHost,
        child: Text(l10n.codexSetupConfigureHost),
      ),
    );
  }

  /// The prompt-variant switch, as an Advanced row: what it does under the
  /// title, when it takes effect behind the title's info mark, and the
  /// upstream issue as a link.
  Widget _nonDegradedRow(
    AppLocalizations l10n,
    ThemeData theme,
    bool nonDegraded,
  ) {
    final status = _status;
    return _MethodRow(
      icon: AppIcons.psychology_outlined,
      live: false,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // When it takes effect is behind the title's info mark; the
                // upstream issue is a link named by its number.
                InfoTitle(
                  title: Text(
                    l10n.codexSetupNonDegradedTitle,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  info: l10n.codexSetupNonDegradedScope,
                ),
                const SizedBox(height: 3),
                Text(
                  l10n.codexSetupNonDegradedDesc,
                  style: helpTextStyle(theme),
                ),
                const SizedBox(height: 4),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    key: const Key('codex-nondegraded-issue'),
                    onTap: () => openUrl(
                      context,
                      'https://github.com/${l10n.codexSetupNonDegradedIssue.replaceFirst('#', '/issues/')}',
                    ),
                    child: Text(
                      l10n.codexSetupNonDegradedIssue,
                      style: helpTextStyle(theme).merge(linkStyleOf(context)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Switch(
            key: const Key('codex-nondegraded-toggle'),
            value: nonDegraded,
            onChanged: (status == null || _busy)
                ? null
                : (on) => _run(
                    () => _api.codexSetPromptVariant(
                      on ? 'non_degraded' : 'default',
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// Where the user stands, in one card: whether codex can call a model at
  /// all, which method got it there, and where its config lives.
  Widget _statusCard(
    AppLocalizations l10n,
    ThemeData theme,
    CodexSetupStatus s,
  ) {
    final scheme = theme.colorScheme;
    // An unreadable config.toml stops hosts on the existing configuration,
    // whatever credential sits beside it.
    final invalid = s.effectiveSource == 'invalid';
    final ready = !s.needsSetup && !invalid;
    final color = ready ? successColor(scheme) : scheme.error;
    final (label, hint) = invalid
        ? (l10n.codexSetupStatusInvalid, l10n.codexSetupStatusInvalidHint)
        : !ready
        ? (l10n.codexSetupStatusNeedSetup, l10n.codexSetupStatusNeedSetupHint)
        : _liveMethod == _Method.provider
        ? (l10n.codexSetupStatusProvider, l10n.codexSetupStatusReadyHint)
        : (
            codexSignedInLabel(l10n, s.authMode),
            l10n.codexSetupStatusReadyHint,
          );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
            child: Row(
              children: [
                IconBadge(
                  icon: ready
                      ? AppIcons.check_circle_outline
                      : AppIcons.error_outline,
                  size: 38,
                  background: color.withValues(alpha: 0.14),
                  foreground: color,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        key: const Key('codex-setup-state'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 3),
                      Text(hint, style: helpTextStyle(theme)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 12, 7),
            // Unfilled: the card is already the ground, so a tinted row inside
            // it would read as a box in a box.
            child: CodeRow(
              value: s.codexHome,
              label: l10n.codexSetupCodexHomeLabel,
              filled: false,
              copyKey: const Key('codex-home-copy'),
            ),
          ),
        ],
      ),
    );
  }
}

/// One access-method row of the methods card: its badge, then [body] (the
/// method's text with its control at the end, and anything the control
/// reports under them).
class _MethodRow extends StatelessWidget {
  const _MethodRow({
    this.rowKey,
    required this.icon,
    required this.live,
    required this.body,
  });

  final Key? rowKey;
  final IconData icon;

  /// Whether codex runs on this method; its badge is accented.
  final bool live;

  final Widget body;

  @override
  Widget build(BuildContext context) => Padding(
    key: rowKey,
    padding: const EdgeInsets.fromLTRB(13, 12, 12, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // On the title's first line rather than centred on the block.
          padding: const EdgeInsets.only(top: 2),
          child: IconBadge(icon: icon, accent: live),
        ),
        const SizedBox(width: 11),
        Expanded(child: body),
      ],
    ),
  );
}

/// A method's title, with an "in use" mark when codex runs on it, its
/// description, and any [notes] about its current state.
class _MethodText extends StatelessWidget {
  const _MethodText({
    required this.title,
    required this.description,
    required this.inUse,
    this.notes = const [],
  });

  final String title;
  final String description;
  final bool inUse;
  final List<Widget> notes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (inUse)
              StatusChip(
                color: successColor(theme.colorScheme),
                label: AppLocalizations.of(context).codexSetupInUse,
                filled: true,
              ),
          ],
        ),
        const SizedBox(height: 3),
        Text(description, style: helpTextStyle(theme)),
        for (final note in notes) ...[const SizedBox(height: 6), note],
      ],
    );
  }
}

/// A quiet caveat under the control it constrains.
class _InlineHint extends StatelessWidget {
  const _InlineHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: helpTextStyle(Theme.of(context)));
}

/// The page's failure line — a tinted panel rather than bare coloured text,
/// so a result under a card stack reads as a result.
class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Container(
      key: const Key('codex-setup-error'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(kPanelRadius),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.error_outline, size: 17, color: color),
          const SizedBox(width: 9),
          // Linkified: a provider URL or an upstream error often carries
          // one, which would otherwise have to be retyped.
          Expanded(
            child: linkifyText(
              context,
              message,
              style: TextStyle(color: color, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
