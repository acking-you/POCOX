import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/network/connection_paths.dart';
import 'package:pocox/src/widgets/glass.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

class _ObservedBridge extends FakeBridgeApi {
  List<SubInfo> observed = [];
  int reads = 0;

  @override
  Future<List<SubInfo>> subscriptions() async {
    reads++;
    return observed;
  }
}

SubInfo _sub(
  TunnelPath path, {
  bool alive = true,
  int direct = 0,
  int relay = 0,
  int fallbacks = 0,
  String? reason,
}) => SubInfo(
  key: 'pcx:studio:app:default',
  localAddr: '127.0.0.1:52011',
  alive: alive,
  path: path,
  activeDirect: direct,
  activeRelay: relay,
  fallbacks: fallbacks,
  lastFallback: reason,
);

extension on SubInfo {
  /// This observation, tracked under [key].
  SubInfo withKey(String key) => SubInfo(
    key: key,
    localAddr: localAddr,
    alive: alive,
    path: path,
    activeDirect: activeDirect,
    activeRelay: activeRelay,
    fallbacks: fallbacks,
    lastFallback: lastFallback,
  );
}

Widget _settings(BridgeApi api, {ThemeData? theme}) => host(
  const Scaffold(body: SingleChildScrollView(child: ConnectionPathSettings())),
  api,
  theme: theme,
);

ConnectionPath? _shown(WidgetTester t) => t
    .widget<GlassSegmented<ConnectionPath?>>(
      find.byKey(const Key('connection-path-outgoing')),
    )
    .selected;

void main() {
  testWidgets(
    'choices save at once, and a failed save keeps what is saved',
    (t) async {
      final api = FakeBridgeApi();
      await t.pumpWidget(_settings(api));
      await t.pumpAndSettle();
      expect(_shown(t), ConnectionPath.relayOnly);
      expect(find.byKey(const Key('connection-path-state')), findsNothing);

      await t.tap(find.byKey(const Key('connection-path-auto')));
      await t.pumpAndSettle();
      expect(api.savedRelayPreferences.path, ConnectionPath.auto);
      expect(find.text('新连接将使用此设置；重新连接会话即可切换。'), findsOneWidget);

      api.relaySaveError = StateError('write failed');
      await t.tap(find.byKey(const Key('connection-path-relay-only')));
      await t.pumpAndSettle();
      expect(api.savedRelayPreferences.path, ConnectionPath.auto);
      expect(_shown(t), ConnectionPath.auto, reason: 'springs back');
      expect(find.text('保存失败，已保留原设置。'), findsOneWidget);

      api.relaySaveError = null;
      final incoming = find.byKey(const Key('connection-path-incoming'));
      expect(incoming, isDesktop ? findsOneWidget : findsNothing);
      if (isDesktop) {
        await t.tap(incoming);
        await t.pumpAndSettle();
        expect(find.text('重启托管后生效。'), findsOneWidget);
      }
      expect(api.savedRelayPreferences.allowDirect, isDesktop);

      // Back to what the page opened with: nothing is pending any more.
      await t.tap(find.byKey(const Key('connection-path-relay-only')));
      await t.pumpAndSettle();
      expect(api.savedRelayPreferences.path, ConnectionPath.relayOnly);
      expect(find.text('新连接将使用此设置；重新连接会话即可切换。'), findsNothing);
      expect(t.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('unreadable preferences offer a retry instead of a guess', (
    t,
  ) async {
    final api = FakeBridgeApi()..relayReadError = StateError('locked');
    await t.pumpWidget(_settings(api));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('connection-path-outgoing')), findsNothing);
    expect(find.text('无法读取连接偏好。'), findsOneWidget);

    api
      ..relayReadError = null
      ..savedRelayPreferences = const RelayPreferences(
        path: ConnectionPath.auto,
      );
    await t.tap(find.byKey(const Key('connection-path-retry')));
    await t.pumpAndSettle();
    expect(_shown(t), ConnectionPath.auto);
  });

  testWidgets('chips follow live observations; polling ends with the view', (
    t,
  ) async {
    final api = _ObservedBridge()..observed = [_sub(TunnelPath.idle)];
    await t.pumpWidget(
      host(
        Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Column(
              children: [
                for (final sub
                    in ref.watch(liveSubscriptionsProvider).valueOrNull ??
                        const <SubInfo>[])
                  TunnelPathChip(sub),
              ],
            ),
          ),
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('空闲'), findsOneWidget);
    expect(find.text('P2P 直连'), findsNothing, reason: 'never the preference');

    api.observed = [_sub(TunnelPath.mixed, direct: 1, relay: 2)];
    await t.pump(const Duration(seconds: 3));
    await t.pumpAndSettle();
    expect(find.text('直连 1 · 中继 2'), findsOneWidget);

    api.observed = [_sub(TunnelPath.direct, alive: false)];
    await t.pump(const Duration(seconds: 3));
    await t.pumpAndSettle();
    expect(find.text('已断开'), findsOneWidget, reason: 'a dropped tunnel');

    await t.pumpWidget(const SizedBox());
    final reads = api.reads;
    await t.pump(const Duration(seconds: 10));
    expect(api.reads, reads);
  });

  testWidgets('details show live counters and the SDK fallback reason', (
    t,
  ) async {
    final api = _ObservedBridge()
      ..observed = [
        _sub(TunnelPath.relay, relay: 1, fallbacks: 2, reason: 'udp_blocked'),
      ];
    await t.pumpWidget(
      host(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showTunnelDetails(context, 'pcx:studio:app:default'),
              child: const Text('open'),
            ),
          ),
        ),
        api,
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    final details = find.byKey(const Key('tunnel-details'));
    expect(details, findsOneWidget);
    expect(
      find.descendant(of: details, matching: find.text('经中继')),
      findsOneWidget,
    );
    expect(find.text('127.0.0.1:52011'), findsOneWidget);
    expect(find.text('udp_blocked'), findsOneWidget);

    api.observed = [_sub(TunnelPath.direct, direct: 1, fallbacks: 2)];
    await t.pump(const Duration(seconds: 3));
    await t.pumpAndSettle();
    expect(
      find.descendant(of: details, matching: find.text('P2P 直连')),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('a connected service says how it travels once observed', (
    t,
  ) async {
    final api = _ObservedBridge()
      ..observed = [_sub(TunnelPath.idle).withKey('pcx:studio:app:default')];
    await t.pumpWidget(
      host(
        const Scaffold(
          body: ConnectedChip(
            serviceKey: 'pcx:studio:app:default',
            label: '已连接',
            color: Colors.green,
          ),
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('已连接'), findsOneWidget, reason: 'idle says nothing');
    api.observed = [_sub(TunnelPath.direct).withKey('pcx:studio:app:default')];
    await t.pump(const Duration(seconds: 3));
    await t.pumpAndSettle();
    expect(find.text('已连接 · P2P'), findsOneWidget);
    api.observed = [
      _sub(TunnelPath.relayOnly).withKey('pcx:studio:app:default'),
    ];
    await t.pump(const Duration(seconds: 3));
    await t.pumpAndSettle();
    expect(find.text('已连接 · 中继'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  for (final width in [320.0, 390.0, 834.0, 1280.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('the group fits at $width px, $brightness', (t) async {
        await t.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => t.binding.setSurfaceSize(null));
        await t.pumpWidget(
          _settings(FakeBridgeApi(), theme: ThemeData(brightness: brightness)),
        );
        await t.pumpAndSettle();
        expect(
          find.byKey(const Key('connection-path-auto')).hitTestable(),
          findsOneWidget,
        );
        expect(t.takeException(), isNull);
      });
    }
  }
}
