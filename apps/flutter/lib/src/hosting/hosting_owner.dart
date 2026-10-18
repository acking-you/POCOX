import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/theme.dart';

/// Whether another POCOX app on this computer owns its hosting state
/// ([BridgeApi.hostingOwnedElsewhere]): this window then hosts, restores and
/// publishes nothing. Read again by each new listener, so it clears once that
/// app has quit.
final hostingElsewhereProvider = Provider.autoDispose<bool>(
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
