import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/service_key.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/hosting/host_picker.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/tools/tools_providers.dart';
import 'package:pocket_codex/src/tools/tools_settings.dart';
import 'package:pocket_codex/src/theme_transition.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/updates/update_settings.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';
import 'package:pocket_codex/src/widgets/github_avatar.dart';
import 'package:pocket_codex/src/widgets/group_card.dart';
import 'package:pocket_codex/src/widgets/icon_badge.dart';
import 'package:pocket_codex/src/widgets/status_dots.dart';
import 'package:pocket_codex/src/widgets/utility_page.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/widgets/app_dialog.dart';
import 'package:pocket_codex/src/widgets/adaptive_sheet.dart';
import 'package:pocket_codex/src/widgets/glass.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';

/// Settings: language, relay/key, subscription status, export.
class SettingsScreen extends ConsumerStatefulWidget {
  /// Default constructor.
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsState();
}

class _SettingsState extends ConsumerState<SettingsScreen> {
  String? _msg;
  late Future<HistoryCacheStatus> _cacheStatus;

  @override
  void initState() {
    super.initState();
    _cacheStatus = ref.read(bridgeApiProvider).historyCacheStatus();
  }

  Widget _cacheTile(AppLocalizations l10n) => FutureBuilder<HistoryCacheStatus>(
    future: _cacheStatus,
    builder: (context, snapshot) => ListTile(
      key: const Key('history-cache-settings'),
      leading: const Icon(AppIcons.storage_outlined),
      title: Text(l10n.historyCacheTitle),
      subtitle: Text(
        snapshot.hasData
            ? l10n.historyCacheUsage(
                (snapshot.data!.usedBytes / 1000000).toStringAsFixed(1),
                snapshot.data!.limitMb,
              )
            : l10n.historyCacheDescription,
      ),
      trailing: const Icon(AppIcons.edit_outlined),
      onTap: () => _editCache(snapshot.data?.limitMb ?? 512),
    ),
  );

  Future<void> _editCache(int current) async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController(text: '$current');
    final form = GlobalKey<FormState>();
    final limit = await showAppDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.historyCacheTitle),
        // The question in words, then the one field: the dialog's body, not
        // a caption under it.
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.historyCacheDescription,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('history-cache-limit'),
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(suffixText: 'MB'),
                validator: (value) {
                  final limit = int.tryParse(value ?? '');
                  return limit == null || limit < 0 || limit > 64000
                      ? l10n.historyCacheInvalid
                      : null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, int.parse(controller.text));
              }
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    // Dialog exit animations can still refer to its controller for this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (limit == null || !mounted) return;
    try {
      final api = ref.read(bridgeApiProvider);
      await api.historyCacheSetLimit(limit);
      if (mounted) setState(() => _cacheStatus = api.historyCacheStatus());
    } catch (error) {
      if (mounted) setState(() => _msg = friendlyError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final api = ref.read(bridgeApiProvider);
    final config = ref.watch(configProvider).valueOrNull;
    final locale = ref.watch(localeProvider);
    final subs =
        ref.watch(subscriptionsProvider).valueOrNull ?? const <SubInfo>[];
    final themeMode = ref.watch(uiPrefsProvider).valueOrNull?.themeMode;
    return UtilityPage(
      route: '/settings',
      title: l10n.settingsTitle,
      body: _wide
          ? _desktopBody(l10n, api, config, locale, subs, themeMode)
          : _compactBody(l10n, api, config, locale, subs, themeMode),
    );
  }

  Widget _compactBody(
    AppLocalizations l10n,
    BridgeApi api,
    ConfigInfo? config,
    Locale? locale,
    List<SubInfo> subs,
    String? themeMode,
  ) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Card(child: _cacheTile(l10n)),
      const Card(child: UpdateRow()),
      Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            ListTile(
              key: const Key('language-btn'),
              title: Text(l10n.language),
              subtitle: Text(_languageLabel(l10n, locale)),
              trailing: const Icon(AppIcons.language),
              onTap: () => _pickLanguage(api),
            ),
            ListTile(
              key: const Key('appearance-btn'),
              title: Text(l10n.appearance),
              subtitle: Text(_appearanceLabel(l10n, themeMode)),
              trailing: const Icon(AppIcons.brightness_6_outlined),
              onTap: _pickAppearance,
            ),
            // Hosting runs on desktop only, as on the manage page.
            if (isDesktop)
              ListTile(
                key: const Key('settings-hosting-btn'),
                leading: const Icon(AppIcons.dns_outlined),
                title: Text(l10n.settingsHosting),
                subtitle: Text(l10n.settingsHostingDesc),
                trailing: const Icon(AppIcons.chevron_right),
                onTap: () => configureHosting(context, ref),
              ),
            ListTile(
              key: const Key('codex-setup-btn'),
              leading: const Icon(AppIcons.tune),
              title: Text(l10n.codexSetup),
              trailing: const Icon(AppIcons.chevron_right),
              onTap: () => context.push('/setup/codex'),
            ),
            const Divider(),
            if (config?.mode == 'account') ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(l10n.accountSection),
              ),
              ListTile(
                leading: GitHubAvatar(
                  accountId: config?.accountId,
                  fallbackIcon: AppIcons.person_outline,
                  size: 32,
                ),
                title: Text('@${config?.accountLogin ?? ''}'),
              ),
              ListTile(
                key: const Key('sign-out-btn'),
                title: Text(l10n.accountSignOut),
                trailing: const Icon(AppIcons.logout),
                onTap: () => _signOut(api),
              ),
              const Divider(),
            ],
            ListTile(
              title: Text(
                config?.mode == 'account'
                    ? l10n.settingsSelfHostedRelay
                    : l10n.relayRow,
              ),
              subtitle: Text(_relayLabel(l10n, config)),
              trailing: const Icon(AppIcons.edit),
              onTap: () => _editRelay(api),
            ),
            ListTile(
              title: Text(
                config?.mode == 'account'
                    ? l10n.settingsSelfHostedKey
                    : l10n.keyRow,
              ),
              subtitle: Text(_keyLabel(l10n, config)),
              trailing: const Icon(AppIcons.edit),
              onTap: () => _editKey(api),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(l10n.activeSubscriptions),
            ),
            if (subs.isEmpty)
              ListTile(dense: true, title: Text(l10n.none))
            else
              ...subs.map(
                (s) => ListTile(
                  dense: true,
                  leading: Icon(
                    AppIcons.circle,
                    size: 12,
                    color: s.alive
                        ? successColor(Theme.of(context).colorScheme)
                        : Theme.of(context).colorScheme.error,
                  ),
                  title: Text(subscriptionServiceKey(s.key)),
                  subtitle: Text(s.localAddr),
                ),
              ),
            const Divider(),
            ListTile(
              key: const Key('export-btn'),
              title: Text(l10n.exportShareString),
              subtitle: _canExport(config)
                  ? null
                  : Text(l10n.settingsExportUnavailable),
              trailing: const Icon(AppIcons.copy),
              onTap: _canExport(config) ? () => _export(api) : null,
            ),
            // Compact needs this as much as desktop and had no route to it. The page
            // menu that carries Logs on desktop is desktop-only, and the one other
            // compact shortcut lives in the chat drawer — which is exactly what a user
            // whose host is unreachable cannot open. That left the logs explaining the
            // failure reachable only after the failure had been fixed.
            ListTile(
              key: const Key('diagnostics-btn'),
              title: Text(l10n.settingsDiagnostics),
              trailing: const Icon(AppIcons.article_outlined),
              onTap: () => context.push('/logs'),
            ),
            if (_msg != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_msg!, key: const Key('settings-msg')),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _desktopBody(
    AppLocalizations l10n,
    BridgeApi api,
    ConfigInfo? config,
    Locale? locale,
    List<SubInfo> subs,
    String? themeMode,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
          child: ListView(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(child: _cacheTile(l10n)),
                  const SizedBox(height: 10),
                  GroupCard(
                    title: l10n.settingsGeneral,
                    children: [
                      _appearanceRow(l10n, themeMode),
                      _SettingsRow(
                        key: const Key('language-btn'),
                        icon: AppIcons.language,
                        title: l10n.language,
                        value: _languageLabel(l10n, locale),
                        onTap: () => _pickLanguage(api),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const UpdateSettings(),
                  const SizedBox(height: 10),
                  GroupCard(
                    title: l10n.settingsHosting,
                    children: [
                      _SettingsRow(
                        key: const Key('settings-hosting-btn'),
                        icon: AppIcons.dns_outlined,
                        title: l10n.codexSetupConfigureHost,
                        onTap: () => configureHosting(context, ref),
                      ),
                    ],
                  ),
                  if (ref.watch(
                    toolsStatusProvider.select((status) => status.supported),
                  )) ...[
                    const SizedBox(height: 10),
                    const AgentToolsSettings(),
                  ],
                  const SizedBox(height: 10),
                  GroupCard(
                    title: 'Codex',
                    children: [
                      _SettingsRow(
                        key: const Key('codex-setup-btn'),
                        icon: AppIcons.auto_awesome_outlined,
                        title: l10n.codexSetup,
                        onTap: () => context.push('/setup/codex'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  GroupCard(
                    title: l10n.settingsAccountConnection,
                    children: [
                      if (config?.mode == 'account')
                        _SettingsRow(
                          icon: AppIcons.account_circle_outlined,
                          leading: GitHubAvatar(
                            accountId: config?.accountId,
                            fallbackIcon: AppIcons.person_outline,
                            size: 32,
                          ),
                          title: '@${config?.accountLogin ?? ''}',
                        ),
                      _SettingsRow(
                        icon: AppIcons.dns_outlined,
                        title: config?.mode == 'account'
                            ? l10n.settingsSelfHostedRelay
                            : l10n.relayRow,
                        subtitle: _relayLabel(l10n, config),
                        actionLabel: l10n.settingsConfigure,
                        onTap: () => _editRelay(api),
                      ),
                      _SettingsRow(
                        icon: AppIcons.key_outlined,
                        title: config?.mode == 'account'
                            ? l10n.settingsSelfHostedKey
                            : l10n.keyRow,
                        subtitle: _keyLabel(l10n, config),
                        actionLabel: config?.hasKey == true
                            ? l10n.settingsEdit
                            : l10n.save,
                        onTap: () => _editKey(api),
                      ),
                      if (config?.mode == 'account')
                        _DangerRow(
                          onPressed: () => _signOut(api),
                          title: l10n.accountSignOut,
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  GroupCard(
                    title: l10n.settingsServicesSubscriptions,
                    children: [
                      if (subs.isEmpty)
                        _SettingsRow(
                          icon: AppIcons.link_off_outlined,
                          title: l10n.none,
                        )
                      else
                        for (final sub in subs)
                          _SettingsRow(
                            icon: AppIcons.link_outlined,
                            title: subscriptionServiceKey(sub.key),
                            subtitle: sub.localAddr,
                            status: StatusChip(
                              color: sub.alive
                                  ? successColor(scheme)
                                  : scheme.error,
                              label: sub.alive
                                  ? l10n.subscribedAlive
                                  : l10n.subscribedDead,
                              filled: true,
                            ),
                          ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  GroupCard(
                    title: l10n.settingsAdvanced,
                    children: [
                      _SettingsRow(
                        key: const Key('export-btn'),
                        icon: AppIcons.ios_share_outlined,
                        title: l10n.exportShareString,
                        subtitle: _canExport(config)
                            ? null
                            : l10n.settingsExportUnavailable,
                        actionLabel: l10n.copy,
                        onTap: _canExport(config) ? () => _export(api) : null,
                      ),
                      _SettingsRow(
                        icon: AppIcons.article_outlined,
                        title: l10n.settingsDiagnostics,
                        onTap: () => context.pushReplacement('/logs'),
                      ),
                    ],
                  ),
                  if (_msg != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _msg!,
                        key: const Key('settings-msg'),
                        style: TextStyle(color: scheme.primary),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The theme choice: a glass segmented control whose pane glides to the
  /// selected mode.
  Widget _appearanceRow(AppLocalizations l10n, String? themeMode) => Padding(
    key: const Key('appearance-btn'),
    padding: const EdgeInsets.fromLTRB(13, 12, 13, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.appearance,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        GlassSegmented<String>(
          selected: themeMode ?? 'system',
          onChanged: (value) => ThemeTransition.run(
            context,
            () => ref
                .read(uiPrefsProvider.notifier)
                .setThemeMode(value == 'system' ? null : value),
          ),
          segments: [
            GlassSegment(
              key: const Key('theme-system'),
              value: 'system',
              icon: AppIcons.brightness_auto_outlined,
              label: l10n.appearanceSystem,
            ),
            GlassSegment(
              key: const Key('theme-light'),
              value: 'light',
              icon: AppIcons.light_mode_outlined,
              label: l10n.appearanceLight,
            ),
            GlassSegment(
              key: const Key('theme-dark'),
              value: 'dark',
              icon: AppIcons.dark_mode_outlined,
              label: l10n.appearanceDark,
            ),
          ],
        ),
      ],
    ),
  );

  String _relayLabel(AppLocalizations l10n, ConfigInfo? config) {
    final value = config?.relay?.trim() ?? '';
    if (value.isNotEmpty) return value;
    return l10n.notConfigured;
  }

  String _keyLabel(AppLocalizations l10n, ConfigInfo? config) {
    return config?.hasKey == true ? l10n.keySet : l10n.keyNotSet;
  }

  bool _canExport(ConfigInfo? config) =>
      (config?.relay?.trim().isNotEmpty ?? false) && config?.hasKey == true;

  Future<void> _export(BridgeApi api) async {
    try {
      final value = await api.exportConfig();
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) {
        _showMessage(AppLocalizations.of(context).copiedShareString);
      }
    } catch (error) {
      _fail(error);
    }
  }

  /// The desktop layout: grouped cards in a centred column.
  bool get _wide => isDesktop && MediaQuery.sizeOf(context).width >= 840;

  void _showMessage(String message) {
    if (!mounted) return;
    setState(() => _msg = message);
    // The inline `_msg` line carries it on compact layouts; wide also toasts,
    // since a message under a long settings list is easy to miss.
    if (_wide) showToast(context, message);
  }

  /// Report an operation that failed, while the page is shown.
  void _fail(Object error) {
    if (!mounted) return;
    _showMessage(
      AppLocalizations.of(
        context,
      ).settingsOperationFailed(friendlyError(error)),
    );
  }

  String _languageLabel(AppLocalizations l10n, Locale? locale) {
    switch (locale?.languageCode) {
      case 'zh':
        return l10n.languageChinese;
      case 'en':
        return l10n.languageEnglish;
      default:
        return l10n.languageSystem;
    }
  }

  String _appearanceLabel(AppLocalizations l10n, String? mode) {
    switch (mode) {
      case 'light':
        return l10n.appearanceLight;
      case 'dark':
        return l10n.appearanceDark;
      default:
        return l10n.appearanceSystem;
    }
  }

  Future<void> _pickAppearance() async {
    final l10n = AppLocalizations.of(context);
    final current =
        ref.read(uiPrefsProvider).valueOrNull?.themeMode ?? 'system';
    final choice = await showChoicePanel<String>(
      context: context,
      title: l10n.appearance,
      current: current,
      choices: [
        ('system', l10n.appearanceSystem),
        ('light', l10n.appearanceLight),
        ('dark', l10n.appearanceDark),
      ],
    );
    if (choice == null || !mounted) return;
    // Let the panel finish closing, so the frame the switch reveals over
    // is the page itself.
    await Future<void>.delayed(const Duration(milliseconds: 260));
    if (!mounted) return;
    ThemeTransition.run(
      context,
      () => ref
          .read(uiPrefsProvider.notifier)
          .setThemeMode(choice == 'system' ? null : choice),
    );
  }

  Future<void> _pickLanguage(BridgeApi api) async {
    final l10n = AppLocalizations.of(context);
    final current = ref.read(localeProvider)?.languageCode ?? 'system';
    final choice = await showChoicePanel<String>(
      context: context,
      title: l10n.language,
      current: current,
      choices: [
        ('system', l10n.languageSystem),
        ('zh', l10n.languageChinese),
        ('en', l10n.languageEnglish),
      ],
    );
    if (choice == null) return;
    try {
      await api.setLocale(choice == 'system' ? '' : choice);
      if (!mounted) return;
      ref.read(localeProvider.notifier).state = choice == 'system'
          ? null
          : Locale(choice);
      setState(() => _msg = null);
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _signOut(BridgeApi api) async {
    try {
      await api.accountLogout();
      ref.invalidate(configProvider);
      if (mounted) context.go('/onboarding');
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _editRelay(BridgeApi api) async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController(
      text: ref.read(configProvider).valueOrNull?.relay ?? '',
    );
    final ok = await _prompt(l10n.relayFieldLabel, ctrl);
    if (ok == true) {
      final relay = ctrl.text.trim();
      if (relay.isEmpty) {
        _showMessage(l10n.relayEmpty);
        return;
      }
      try {
        await api.setRelay(relay);
        if (mounted) setState(() => _msg = null);
        ref.invalidate(configProvider);
        ref.invalidate(servicesProvider);
      } catch (error) {
        _fail(error);
      }
    }
  }

  Future<void> _editKey(BridgeApi api) async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    final ok = await _prompt(l10n.keyFieldLabel, ctrl, obscure: true);
    if (ok == true) {
      final key = ctrl.text.trim();
      if (key.length != 32) {
        _showMessage(l10n.keyLengthError);
        return;
      }
      try {
        await api.setKey(key);
        if (mounted) setState(() => _msg = null);
        ref.invalidate(configProvider);
      } catch (error) {
        _fail(error);
      }
    }
  }

  Future<bool?> _prompt(
    String label,
    TextEditingController ctrl, {
    bool obscure = false,
  }) {
    final l10n = AppLocalizations.of(context);
    return showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: TextField(
          controller: ctrl,
          obscureText: obscure,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.leading,
    this.subtitle,
    this.value,
    this.status,
    this.actionLabel,
    this.onTap,
  });

  final IconData icon;
  final String title;

  /// Replaces the [icon] tile, for a row whose subject has a picture of its own.
  final Widget? leading;
  final String? subtitle;
  final String? value;
  final Widget? status;
  final String? actionLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(13, 8, 8, 8),
      child: Row(
        children: [
          leading ?? IconBadge(icon: icon),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: helpTextStyle(Theme.of(context)),
                  ),
                ],
              ],
            ),
          ),
          if (value != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                value!,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          if (status != null) ...[status!, const SizedBox(width: 8)],
          if (actionLabel != null)
            OutlinedButton(onPressed: onTap, child: Text(actionLabel!))
          else if (onTap != null)
            Icon(AppIcons.chevron_right, color: scheme.onSurfaceVariant),
        ],
      ),
    );
    if (onTap == null || actionLabel != null) return content;
    return InkWell(mouseCursor: clickable, onTap: onTap, child: content);
  }
}

class _DangerRow extends StatelessWidget {
  const _DangerRow({required this.onPressed, required this.title});

  final VoidCallback onPressed;
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      child: Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton.icon(
          key: const Key('sign-out-btn'),
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: scheme.error,
            side: BorderSide(color: scheme.error),
          ),
          icon: const Icon(AppIcons.logout, size: 17),
          label: Text(title),
        ),
      ),
    );
  }
}
