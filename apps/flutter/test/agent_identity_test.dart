import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';

import 'fake_bridge_api.dart';

void main() {
  test(
    'An identity from the previous transport cannot replace the current one',
    () async {
      const key = 'pcx:studio:acp:work';
      final api = FakeBridgeApi();
      final old = Completer<AgentIdentity>();
      api.agentIdentityReplies[key] = old.future;
      final container = ProviderContainer(
        overrides: [bridgeApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final provider = agentIdentityProvider(key);
      container.listen(provider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      expect(api.agentIdentityCalls, [key]);

      const current = AgentIdentity(
        provider: 'acp',
        profileId: 'grok',
        name: 'Grok Build',
      );
      api.agentIdentityReplies.remove(key);
      api.agentIdentities[key] = current;
      container.invalidate(configProvider);
      expect(await container.read(provider.future), same(current));

      old.complete(
        const AgentIdentity(
          provider: 'acp',
          profileId: 'claude',
          name: 'Claude',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(provider).requireValue, same(current));
      expect(api.appIsConnected(key), isFalse);
    },
  );
}
