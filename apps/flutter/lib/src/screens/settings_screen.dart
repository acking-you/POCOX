import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/service_key.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/error_format.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/hosting/host_picker.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/network/network_settings.dart';
import 'package:pocox/src/network/connection_paths.dart';
import 'package:pocox/src/network/connection_window.dart';
import 'package:pocox/src/pairing/pairing_account.dart';
import 'package:pocox/src/tools/tools_providers.dart';
import 'package:pocox/src/tools/tools_settings.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/theme_transition.dart';
import 'package:pocox/src/ui_prefs.dart';
import 'package:pocox/src/updates/update_controller.dart';
import 'package:pocox/src/updates/update_settings.dart';
import 'package:pocox/src/widgets/app_toast.dart';
import 'package:pocox/src/widgets/github_avatar.dart';
import 'package:pocox/src/widgets/group_card.dart';
import 'package:pocox/src/widgets/pocket_sheet.dart';
import 'package:pocox/src/widgets/setting_row.dart';
import 'package:pocox/src/widgets/status_dots.dart';
import 'package:pocox/src/widgets/utility_page.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/widgets/app_dialog.dart';
import 'package:pocox/src/widgets/adaptive_sheet.dart';
import 'package:pocox/src/widgets/glass.dart';
import 'package:pocox/src/widgets/workspace_navigation.dart';

part 'settings/settings_sections.dart';
part 'settings/settings_values.dart';

/// The sections of Settings, in the order a wide window's column lists them.
enum SettingsSection {
  /// Appearance and language.
  general,

  /// The path, the retained window, the proxy and the active subscriptions.
  connection,

  /// Hosting and agent setup.
  agents,

  /// The cache, the logs and the export.
  storage,

  /// The account, or the relay of a self-hosted setup.
  account,

  /// The version and its update.
  about;

  /// The section a route segment names, or null for any other.
  static SettingsSection? parse(String? segment) =>
      values.where((section) => section.name == segment).firstOrNull;
}

/// Settings. One model of its sections with two renderers: a compact window
/// shows a root of labelled rows with a page per section, a wide one lists the
/// sections in the workspace's column beside the chosen one's page.
class SettingsScreen extends ConsumerStatefulWidget {
  /// Default constructor; [section] is the page a route asks for.
  const SettingsScreen({super.key, this.section});

  /// The section this route opens on; null is the root.
  final SettingsSection? section;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsState();
}

class _SettingsState extends ConsumerState<SettingsScreen> {
  String? _msg;
  late Future<HistoryCacheStatus> _cacheStatus;

  /// The section a wide window shows.
  late SettingsSection _selected = widget.section ?? SettingsSection.general;

  @override
  void initState() {
    super.initState();
    _cacheStatus = ref.read(bridgeApiProvider).historyCacheStatus();
  }

  @override
  void didUpdateWidget(SettingsScreen old) {
    super.didUpdateWidget(old);
    if (widget.section case final section? when section != old.section) {
      _selected = section;
    }
  }

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

  /// The wide layout.
  bool get _wide => MediaQuery.sizeOf(context).width >= workspaceCompactWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final model = _sections(l10n);
    if (_wide) {
      final section = model.firstWhere((s) => s.id == _selected);
      return UtilityPage(
        route: '/settings',
        title: section.label,
        lead: l10n.settingsTitle,
        column: _sectionList(l10n, model),
        body: _sectionPage(section),
      );
    }
    final section = widget.section;
    if (section == null) {
      return UtilityPage(
        route: '/settings',
        title: l10n.settingsTitle,
        body: _root(l10n, model),
      );
    }
    final page = model.firstWhere((s) => s.id == section);
    return UtilityPage(
      route: '/settings',
      title: page.label,
      parent: UtilityParent(title: l10n.settingsTitle, route: '/settings'),
      body: _sectionPage(page),
    );
  }

  /// A compact window's root: the account or relay, then every section's rows
  /// under its name.
  Widget _root(AppLocalizations l10n, List<_Section> model) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    children: [
      _identityRow(),
      for (final section in model)
        if (section.rows.isNotEmpty)
          GroupCard(
            key: Key('settings-group-${section.id.name}'),
            title: section.label,
            children: section.rows,
          ),
      ?_message(),
    ],
  );

  /// The header of a compact root: who is signed in, or the relay.
  Widget _identityRow() {
    final scheme = Theme.of(context).colorScheme;
    const radius = BorderRadius.all(Radius.circular(kCardRadius));
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: raisedCardShadows(scheme),
        ),
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const Key('settings-identity'),
            mouseCursor: clickable,
            onTap: () =>
                context.push('/settings/${SettingsSection.account.name}'),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 68),
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 12, 10),
                child: Row(
                  children: [
                    const Expanded(child: PocketIdentity()),
                    const SizedBox(width: 6),
                    Icon(
                      AppIcons.chevron_right,
                      size: 18,
                      color: onSurfaceMuted(scheme),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A wide window's column: the sections.
  Widget _sectionList(AppLocalizations l10n, List<_Section> model) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(kControlRadius);
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 50,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: 18),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  l10n.settingsTitle,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              children: [
                for (final section in model)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Material(
                      color: section.id == _selected
                          ? softWash(scheme)
                          : Colors.transparent,
                      borderRadius: radius,
                      child: InkWell(
                        key: Key('settings-section-${section.id.name}'),
                        mouseCursor: clickable,
                        borderRadius: radius,
                        hoverColor: softWash(scheme),
                        onTap: () => setState(() => _selected = section.id),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: isDesktop ? 36 : 44,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Row(
                              children: [
                                section.leading ??
                                    Icon(
                                      section.icon,
                                      size: 16,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    section.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: section.id == _selected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One section's page: the same on both, narrower than a wide window.
  Widget _sectionPage(_Section section) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ListView(
        key: Key('settings-page-${section.id.name}'),
        padding: EdgeInsets.fromLTRB(16, _wide ? 0 : 4, 16, 24),
        children: [
          if (_wide)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 22, 14, 10),
              child: Text(
                section.label,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ...section.page,
          ?_message(),
        ],
      ),
    ),
  );

  /// What the last operation left to say.
  Widget? _message() {
    final message = _msg;
    if (message == null) return null;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(message, key: const Key('settings-msg')),
    );
  }

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

  void _showMessage(String message) {
    if (!mounted) return;
    setState(() => _msg = message);
    // The inline line carries it on compact layouts; wide also toasts, since a
    // message under a long settings list is easy to miss.
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
