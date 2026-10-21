import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/widgets/app_toast.dart';

/// A raw error, folded under a problem's cause in words: whole, selectable
/// and copyable once opened.
class ErrorDetails extends StatelessWidget {
  /// Folds [detail]; [tileKey] keys the fold's header.
  const ErrorDetails({super.key, required this.detail, this.tileKey});

  /// The error as the system reported it.
  final String detail;

  /// The key of the tile that opens the fold.
  final Key? tileKey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Material(
      // An own ink layer: a coloured ancestor would hide the tile's.
      type: MaterialType.transparency,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: tileKey,
          tilePadding: EdgeInsets.zero,
          dense: true,
          childrenPadding: const EdgeInsets.only(bottom: 10),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          title: Text(
            l10n.errorDetails,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          children: [
            SelectableText(
              detail,
              style: TextStyle(
                fontFamily: monoFontFamily,
                fontFamilyFallback: monoCjkFallback,
                fontSize: 12,
                height: 1.45,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: detail));
                  if (context.mounted) showToast(context, l10n.copied);
                },
                icon: const Icon(AppIcons.copy, size: 16),
                label: Text(l10n.copy),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
