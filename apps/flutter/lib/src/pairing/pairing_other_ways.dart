import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/pairing/pairing_widgets.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/adaptive_sheet.dart';

/// A way to sign in that sign-in keeps behind "Other ways to sign in", so the
/// page itself shows at most three actions.
@immutable
class PairingOtherWay {
  /// Creates a way; [onSelected] runs once its panel has closed.
  const PairingOtherWay({
    required this.key,
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  /// The row's key, the same one the action had on the page.
  final Key key;

  /// The row's icon.
  final IconData icon;

  /// The row's label.
  final String label;

  /// What choosing it does.
  final VoidCallback onSelected;
}

/// Sign-in's last, quiet action: opens [ways] in a sheet on a phone and a
/// dialog on a computer, with [advanced] folded into its last row. An open
/// panel follows the page: rows the page stops offering leave it.
class PairingOtherWaysButton extends StatefulWidget {
  /// Creates the button.
  const PairingOtherWaysButton({
    super.key,
    required this.ways,
    this.advanced,
    this.enabled = true,
  });

  /// The rows, in order.
  final List<PairingOtherWay> ways;

  /// The self-hosted settings Advanced reveals in the panel; no Advanced row
  /// without it.
  final WidgetBuilder? advanced;

  /// Whether it can open now.
  final bool enabled;

  @override
  State<PairingOtherWaysButton> createState() => _PairingOtherWaysState();
}

class _PairingOtherWaysState extends State<PairingOtherWaysButton> {
  late final _ways = ValueNotifier(widget.ways);

  @override
  void didUpdateWidget(PairingOtherWaysButton old) {
    super.didUpdateWidget(old);
    // The panel is another route: tell it after this frame's build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ways.value = widget.ways;
    });
  }

  @override
  void dispose() {
    _ways.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextButton(
      key: const Key('pairing-other-ways'),
      onPressed: widget.enabled
          ? () => showAdaptivePanel<void>(
              context: context,
              builder: (_) => ValueListenableBuilder(
                valueListenable: _ways,
                builder: (_, ways, _) =>
                    _OtherWaysPanel(ways: ways, advanced: widget.advanced),
              ),
            )
          : null,
      child: Text(AppLocalizations.of(context).pairingOtherWays),
    );
  }
}

class _OtherWaysPanel extends StatefulWidget {
  const _OtherWaysPanel({required this.ways, this.advanced});

  final List<PairingOtherWay> ways;
  final WidgetBuilder? advanced;

  @override
  State<_OtherWaysPanel> createState() => _OtherWaysPanelState();
}

class _OtherWaysPanelState extends State<_OtherWaysPanel> {
  bool _advancedOpen = false;

  Widget _row({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool open = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      key: key,
      mouseCursor: clickable,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(icon, size: 19, color: scheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
              Icon(
                open ? AppIcons.expand_more : AppIcons.chevron_right,
                size: 18,
                color: onSurfaceMuted(scheme),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final advanced = widget.advanced;
    return Padding(
      // The backend field must stay above a phone's keyboard.
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.pairingOtherWays,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 14),
          PairingPlate([
            for (final way in widget.ways)
              _row(
                key: way.key,
                icon: way.icon,
                label: way.label,
                onTap: () {
                  Navigator.of(context).pop();
                  way.onSelected();
                },
              ),
            if (advanced != null)
              _row(
                key: const Key('account-advanced'),
                icon: AppIcons.tune,
                label: l10n.accountAdvanced,
                open: _advancedOpen,
                onTap: () => setState(() => _advancedOpen = !_advancedOpen),
              ),
          ]),
          if (advanced != null && _advancedOpen) ...[
            const SizedBox(height: 14),
            advanced(context),
          ],
        ],
      ),
    );
  }
}
