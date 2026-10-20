/// Updates' app-wide presence: it starts the quiet background check and,
/// once per newer release, offers it in a toast whose one button updates.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/router.dart';
import 'package:pocket_codex/src/updates/update_api.dart';
import 'package:pocket_codex/src/updates/update_controller.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';

/// Wraps the app's pages with the update check and its offer.
class UpdateHost extends ConsumerStatefulWidget {
  /// Hosts the update flow above [child].
  const UpdateHost({super.key, required this.child});

  /// The pages.
  final Widget child;

  @override
  ConsumerState<UpdateHost> createState() => _UpdateHostState();
}

class _UpdateHostState extends ConsumerState<UpdateHost> {
  @override
  void initState() {
    super.initState();
    // After the first frame: the check never competes with startup.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(updateApiProvider).updateStartBackground();
    });
  }

  void _offer(UpdateState state) {
    final latest = state.latest;
    if (!state.newer ||
        state.phase != 'available' ||
        latest == null ||
        latest == state.announced) {
      return;
    }
    // Once per version, whether or not the user acts on it: Settings keeps
    // offering it after the toast has gone.
    ref.read(updateApiProvider).updateAnnounce(latest);
    final l10n = AppLocalizations.of(context);
    final actions = ref.read(updateActionsProvider);
    final page = state.method == 'release_page';
    ToastMessenger.of(context).offer(
      l10n.updateToast(latest),
      action: page ? l10n.updateReleasePage : l10n.updateInstall,
      onAction: () {
        if (page) {
          actions.openPage();
          return;
        }
        // The update shows its progress on the Settings button.
        openSettingsFromTray();
        actions.updateNow();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<UpdateState>>(updateStateProvider, (_, next) {
      if (next.valueOrNull case final state?) _offer(state);
    });
    return widget.child;
  }
}
