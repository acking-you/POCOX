part of '../settings_screen.dart';

/// One section of Settings: its name, its rows on a compact root, and what its
/// page shows.
class _Section {
  const _Section({
    required this.id,
    required this.icon,
    required this.label,
    required this.rows,
    required this.page,
    this.leading,
  });

  final SettingsSection id;
  final IconData icon;
  final String label;

  /// The section's picture in the column, in place of [icon].
  final Widget? leading;

  /// Its rows on the compact root: label, current value, chevron.
  final List<Widget> rows;

  /// What its page lays out.
  final List<Widget> page;
}

extension _SettingsSections on _SettingsState {
  void _openSection(SettingsSection section) =>
      context.push('/settings/${section.name}');

  void _openLogs() => openWorkspaceRoute(context, '/settings', '/logs');

  /// Every section, in order. The account's page leads a compact root through
  /// its header, not through rows.
  List<_Section> _sections(AppLocalizations l10n) {
    final api = ref.read(bridgeApiProvider);
    final config = ref.watch(configProvider).valueOrNull;
    final locale = ref.watch(localeProvider);
    final themeMode = ref.watch(
      uiPrefsProvider.select((prefs) => prefs.valueOrNull?.themeMode),
    );
    final account = config?.mode == 'account';
    final toolsSupported = ref.watch(
      toolsStatusProvider.select((status) => status.supported),
    );
    Widget language() => SettingValueRow(
      key: const Key('language-btn'),
      label: l10n.language,
      value: Text(_languageLabel(l10n, locale)),
      onTap: () => _pickLanguage(api),
    );
    Widget cache() => FutureBuilder<HistoryCacheStatus>(
      future: _cacheStatus,
      builder: (context, snapshot) => SettingValueRow(
        key: const Key('history-cache-settings'),
        label: l10n.historyCacheTitle,
        value: snapshot.hasData
            ? Text(
                l10n.historyCacheValue(
                  (snapshot.data!.usedBytes / 1000000).toStringAsFixed(1),
                  snapshot.data!.limitMb,
                ),
              )
            : null,
        onTap: () => _editCache(snapshot.data?.limitMb ?? 512),
      ),
    );
    Widget logs() => SettingValueRow(
      key: const Key('diagnostics-btn'),
      label: l10n.logsTitle,
      onTap: _openLogs,
    );
    Widget export() => SettingValueRow(
      key: const Key('export-btn'),
      label: l10n.exportShareString,
      info: _canExport(config) ? null : l10n.settingsExportUnavailable,
      onTap: _canExport(config) ? () => _export(api) : null,
    );
    Widget codexSetup() => SettingValueRow(
      key: const Key('codex-setup-btn'),
      label: l10n.codexSetup,
      onTap: () => context.push('/setup/codex'),
    );
    Widget hosting() => SettingValueRow(
      key: const Key('settings-hosting-btn'),
      label: l10n.settingsHosting,
      info: l10n.settingsHostingDesc,
      onTap: () => configureHosting(context, ref),
    );
    return [
      _Section(
        id: SettingsSection.general,
        icon: AppIcons.dark_mode_outlined,
        label: l10n.settingsGeneral,
        rows: [
          SettingValueRow(
            key: const Key('appearance-btn'),
            label: l10n.appearance,
            value: Text(appearanceLabel(l10n, themeMode)),
            onTap: () => pickAppearance(context, ref),
          ),
          language(),
        ],
        page: [
          GroupCard(
            title: l10n.settingsGeneral,
            children: [_appearanceRow(l10n, themeMode), language()],
          ),
        ],
      ),
      _Section(
        id: SettingsSection.connection,
        icon: AppIcons.route,
        label: l10n.settingsConnection,
        rows: [
          for (final (key, label, value) in <(String, String, Widget)>[
            (
              'settings-connection-path',
              l10n.connectionPathTitle,
              const _ConnectionPathValue(),
            ),
            (
              'settings-connection-window',
              l10n.connectionWindowTitle,
              const _ConnectionWindowValue(),
            ),
            (
              'settings-connection-proxy',
              l10n.networkProxyTitle,
              const _NetworkProxyValue(),
            ),
            (
              'settings-connection-subscriptions',
              l10n.activeSubscriptions,
              const _SubscriptionCount(),
            ),
          ])
            SettingValueRow(
              key: Key(key),
              label: label,
              value: value,
              onTap: () => _openSection(SettingsSection.connection),
            ),
        ],
        page: [
          // How this device reaches the services below, then what each
          // subscription actually goes through.
          const ConnectionPathSettings(),
          const ConnectionWindowSettings(),
          GroupCard(
            title: l10n.settingsNetwork,
            children: const [NetworkProxyRow()],
          ),
          const _SubscriptionsGroup(),
        ],
      ),
      _Section(
        id: SettingsSection.agents,
        icon: AppIcons.tune,
        label: isDesktop ? l10n.settingsAgentsHosting : l10n.settingsAgents,
        rows: [
          // Hosting runs on a computer only, as on the services page.
          if (isDesktop) hosting(),
          if (toolsSupported)
            SettingValueRow(
              key: const Key('settings-agent-tools'),
              label: l10n.toolsTitle,
              onTap: () => _openSection(SettingsSection.agents),
            ),
          codexSetup(),
        ],
        page: [
          GroupCard(
            title: isDesktop ? l10n.settingsAgentsHosting : l10n.settingsAgents,
            children: [if (isDesktop) hosting(), codexSetup()],
          ),
          if (toolsSupported) const AgentToolsSettings(),
        ],
      ),
      _Section(
        id: SettingsSection.storage,
        icon: AppIcons.storage_outlined,
        label: l10n.settingsStorageDiagnostics,
        rows: [cache(), logs(), export()],
        page: [
          GroupCard(
            title: l10n.settingsStorageDiagnostics,
            children: [cache(), logs(), export()],
          ),
        ],
      ),
      _Section(
        id: SettingsSection.account,
        icon: AppIcons.account_circle_outlined,
        label: account ? l10n.accountSection : l10n.settingsRelay,
        leading: account
            ? GitHubAvatar(
                accountId: config?.accountId,
                fallbackIcon: AppIcons.person_outline,
                size: 16,
              )
            : null,
        // A compact root heads the page with this section instead.
        rows: const [],
        page: [
          GroupCard(
            title: account ? l10n.accountSection : l10n.settingsRelay,
            children: [
              if (account)
                const Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(14, 12, 12, 12),
                  child: PocketIdentity(),
                ),
              SettingValueRow(
                key: const Key('settings-relay'),
                label: account ? l10n.settingsSelfHostedRelay : l10n.relayRow,
                value: Text(_relayLabel(l10n, config)),
                onTap: () => _editRelay(api),
              ),
              SettingValueRow(
                key: const Key('settings-key'),
                label: account ? l10n.settingsSelfHostedKey : l10n.keyRow,
                value: Text(_keyLabel(l10n, config)),
                onTap: () => _editKey(api),
              ),
              if (account)
                _DangerRow(
                  onPressed: () => _signOut(api),
                  title: l10n.accountSignOut,
                ),
            ],
          ),
        ],
      ),
      _Section(
        id: SettingsSection.about,
        icon: AppIcons.info_outline,
        label: l10n.settingsAbout,
        rows: [
          _UpdateValueRow(onTap: () => _openSection(SettingsSection.about)),
        ],
        page: const [UpdateSettings()],
      ),
    ];
  }

  /// The theme choice on a wide page: a glass segmented control whose pane
  /// glides to the selected mode.
  Widget _appearanceRow(AppLocalizations l10n, String? themeMode) => Padding(
    key: const Key('appearance-btn'),
    padding: const EdgeInsets.fromLTRB(14, 12, 13, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.appearance),
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
}
