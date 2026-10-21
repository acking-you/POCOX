import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/hosting/editor_block.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/theme.dart';

/// Whether another POCOX app on this computer owned its hosting state when
/// this one started ([BridgeApi.hostingOwnedElsewhere]): this window then
/// hosts, restores and publishes nothing for its whole run.
final hostingElsewhereProvider = Provider<bool>(
  (ref) => ref.watch(bridgeApiProvider).hostingOwnedElsewhere(),
);

/// Why this window offers no hosting: another POCOX app on this computer
/// hosts its services.
class HostingElsewhereNote extends StatelessWidget {
  /// Creates the note.
  const HostingElsewhereNote({super.key});

  @override
  Widget build(BuildContext context) => EditorNote(
    AppLocalizations.of(context).hostingElsewhere,
    key: const Key('hosting-elsewhere'),
    color: cautionColor(Theme.of(context).colorScheme),
  );
}
