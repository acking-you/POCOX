/// Agent tools state: every device's services, shares and consent requests,
/// followed live, and this installation's switch.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';

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

/// This installation's switch, endpoint and problem: read when a page shows
/// it, again on every catalog update (a change made elsewhere, such as
/// `pocox tools disable` or a moved port, brings one), and replaced by the
/// answer to a change made here.
final toolsStatusProvider = StateProvider.autoDispose<AgentToolsStatus>((ref) {
  ref.watch(toolsUpdatesProvider);
  return ref.watch(bridgeApiProvider).toolsStatus();
});

/// Port keys connected here for a share, automatically or on Open, with the
/// device that shares them: [ToolsHost] ends each when its share ends, so a
/// share never leaves a tunnel to nothing behind.
final shareConnectionsProvider = Provider<Map<String, String>>((ref) => {});

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
