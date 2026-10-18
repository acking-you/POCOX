/// Agent tools state: every device's services, shares and consent requests,
/// followed live, and this installation's switch.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';

/// The live stream of updates from every device's catalog. Kept alive by the
/// app-wide [ToolsHost], so every page reads the same subscription.
final toolsUpdatesProvider = StreamProvider<ToolsUpdate>(
  (ref) => ref.watch(bridgeApiProvider).toolsWatch(),
);

/// Every device and service visible now (empty before the first answer).
final toolsOverviewProvider = Provider<ToolsOverview>(
  (ref) =>
      ref.watch(toolsUpdatesProvider).valueOrNull?.overview ??
      ToolsOverview.empty,
);

/// This installation's switch, re-read after every change.
final toolsStatusProvider = StateProvider<AgentToolsStatus>(
  (ref) => ref.watch(bridgeApiProvider).toolsStatus(),
);

/// Every share across the user's devices, newest first.
final toolsSharesProvider =
    Provider<List<({ToolsDevice device, ToolsShare share})>>(
      (ref) => ref.watch(toolsOverviewProvider).shares,
    );

/// Consent requests waiting for the user, oldest first.
final toolsConsentsProvider =
    Provider<List<({ToolsDevice device, ToolsConsent consent})>>(
      (ref) => ref.watch(toolsOverviewProvider).consents,
    );
