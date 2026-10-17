import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/screens/services_screen.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

const _manager = 'pcx:studio:host:pocket';
const _windows = DeviceMetadata(
  os: 'windows',
  arch: 'x86_64',
  hostname: 'studio',
  instanceId: 'windows-app',
);
const _wsl = DeviceMetadata(
  os: 'linux',
  arch: 'x86_64',
  environment: 'wsl',
  hostname: 'studio',
  instanceId: 'wsl-cli',
);

Future<void> _show(
  WidgetTester t,
  FakeBridgeApi api, {
  double width = 1200,
}) async {
  t.view.physicalSize = Size(width, 1200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(host(const ServicesScreen(), api));
  await t.pumpAndSettle();
}

String? _platform(WidgetTester t) {
  final line = find.byKey(const Key('device-detail-platform'));
  return line.evaluate().isEmpty ? null : t.widget<Text>(line).data;
}

/// A remote computer, managed from here, with the same hostname as this one.
FakeBridgeApi _sameNameWsl({bool localHost = false}) {
  final api =
      FakeBridgeApi(
          services: const [
            ServiceEntry(
              device: 'studio',
              kind: 'host',
              name: 'pocket',
              key: _manager,
            ),
          ],
        )
        ..localMetadata = _windows
        ..acpHosting = false;
  if (localHost) {
    api.serveHosts.add(
      const AppServeStatus(
        name: 'local',
        device: 'studio',
        alive: true,
        appServiceKey: 'pcx:studio:app:local',
      ),
    );
  }
  api.managedDevices[_manager] = const ManagedDevice(
    device: 'studio',
    os: 'linux',
    metadata: _wsl,
    appVersion: '0.3.0',
  );
  return api;
}

void main() {
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);

  testWidgets('Windows and WSL with the same hostname keep independent '
      'hosting controls and remote Claude support', (t) async {
    final api = _sameNameWsl(localHost: true);
    api.managedRuntimeLists[_manager] = const [
      ManagedRuntimeAvailability(kind: 'claude', ready: true),
    ];
    await _show(t, api);
    expect(find.byKey(const Key('device-@local')), findsOneWidget);
    expect(find.byKey(const Key('device-studio')), findsOneWidget);
    // This computer, with a host, opens first and names its own platform.
    expect(_platform(t), 'Windows · x86_64');

    await tapKey(t, 'device-studio');
    expect(_platform(t), 'Linux · WSL · x86_64');
    expect(find.byKey(const Key('managed-device-studio')), findsOneWidget);
    expect(find.byKey(const Key('add-local-host-card')), findsNothing);
    expect(find.byKey(const Key('device-management-switch')), findsNothing);
    expect(api.metadataReads, isEmpty, reason: 'reuse management metadata');

    await tapKey(t, 'managed-add-service');
    await tapKey(t, 'managed-runtime-claude');
    expect(find.byKey(const Key('managed-create')), findsOneWidget);
    expect(find.byKey(const Key('acp-hosting-unsupported')), findsNothing);
    expect(api.managedCalls, isEmpty, reason: 'opening never starts a service');
    expect(t.takeException(), isNull);
  }, variant: windows);

  testWidgets('a desktop with no local service never attaches its controls '
      'to the selected remote device, even on a narrow screen', (t) async {
    final api = _sameNameWsl();
    await _show(t, api, width: 393);
    await tapKey(t, 'device-studio');
    expect(find.byKey(const Key('add-local-host-card')), findsNothing);
    expect(find.byKey(const Key('device-management-switch')), findsNothing);
    expect(_platform(t), 'Linux · WSL · x86_64');
    await tapKey(t, 'device-back');
    await tapKey(t, 'device-@local');
    expect(find.byKey(const Key('add-local-host-card')), findsOneWidget);
    expect(find.byKey(const Key('managed-device-studio')), findsNothing);
    expect(_platform(t), 'Windows · x86_64');
    expect(t.takeException(), isNull);
  }, variant: windows);

  testWidgets('metadata reads only the selected host, once, and a late '
      'response cannot replace another device platform', (t) async {
    const first = 'pcx:first:app:default';
    const second = 'pcx:second:app:default';
    final gate = Completer<void>();
    final api =
        FakeBridgeApi(
            services: const [
              ServiceEntry(
                device: 'first',
                kind: 'app',
                name: 'default',
                key: first,
              ),
              ServiceEntry(
                device: 'second',
                kind: 'app',
                name: 'default',
                key: second,
              ),
            ],
          )
          ..localMetadata = _windows
          ..metadataGate = gate;
    api.serviceMetadata[first] = _wsl;
    api.serviceMetadata[second] = const DeviceMetadata(
      os: 'macos',
      arch: 'aarch64',
      hostname: 'second',
      instanceId: 'mac-app',
    );
    await _show(t, api);
    // Wide layouts open on the first remote device while this computer has
    // nothing to show; the header waits rather than claiming "unknown".
    expect(api.metadataReads, [first]);
    expect(_platform(t), isNull);
    // The re-probe timer does not re-read what only a restart changes.
    await t.pump(const Duration(seconds: 16));
    await t.pumpAndSettle();
    expect(api.metadataReads, [first]);
    await tapKey(t, 'device-second');
    expect(api.metadataReads, [first, second]);
    gate.complete();
    await t.pumpAndSettle();
    expect(_platform(t), 'macOS · aarch64');
    expect(find.text('Linux · WSL · x86_64'), findsNothing);
    expect(find.byKey(const Key('add-local-host-card')), findsNothing);
  }, variant: windows);

  testWidgets('legacy and unreachable hosts keep platform unknown; a failed '
      'read retries by itself, an answer only on refresh', (t) async {
    const key = 'pcx:legacy:api:default';
    final api = FakeBridgeApi(
      services: const [
        ServiceEntry(device: 'legacy', kind: 'api', name: 'default', key: key),
      ],
    )..localMetadata = _windows;
    await _show(t, api);
    await tapKey(t, 'device-legacy');
    expect(_platform(t), '平台未知');
    api.metadataError = StateError('host offline');
    await tapKey(t, 'refresh-btn');
    expect(_platform(t), '平台未知');
    expect(find.byKey(const Key('add-local-host-card')), findsNothing);
    api.metadataError = null;
    api.serviceMetadata[key] = _wsl;
    // The host came back: the failed read is retried without a refresh.
    await t.pump(const Duration(seconds: 16));
    await t.pumpAndSettle();
    expect(_platform(t), 'Linux · WSL · x86_64');
    final reads = api.metadataReads.length;
    await t.pump(const Duration(seconds: 16));
    await t.pumpAndSettle();
    expect(api.metadataReads, hasLength(reads), reason: 'answers are kept');
    expect(t.takeException(), isNull);
  }, variant: windows);

  testWidgets('same-name Windows and WSL installations are named by their '
      'source, and a stop reaches only the chosen installation', (t) async {
    t.view.physicalSize = const Size(1200, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    const identities = [
      (os: 'windows', environment: null, source: null, id: '11111111'),
      (os: 'linux', environment: 'wsl', source: 'Ubuntu', id: '22222222'),
      (os: 'linux', environment: 'wsl', source: 'Debian', id: '33333333'),
      (os: 'linux', environment: 'wsl', source: 'Ubuntu', id: '44444444'),
    ];
    final api = FakeBridgeApi();
    final devices = <String>[];
    final managers = <String>[];
    for (final identity in identities) {
      final id = '${identity.id}-1234-4123-8123-123456789abc';
      final source = [
        identity.environment ?? identity.os,
        ?identity.source?.toLowerCase(),
      ].join('-');
      final device = '$source.studio.${id.replaceAll('-', '')}';
      final manager = 'pcx:$device:host:pocket';
      devices.add(device);
      managers.add(manager);
      api.services.add(
        ServiceEntry(
          device: device,
          kind: 'host',
          name: 'pocket',
          key: manager,
        ),
      );
      api.managedDevices[manager] = ManagedDevice(
        device: device,
        os: identity.os,
        metadata: DeviceMetadata(
          os: identity.os,
          environment: identity.environment,
          sourceName: identity.source,
          hostname: 'studio',
          arch: 'x86_64',
          hostId: id,
          instanceId: 'process-${identity.id}',
        ),
        appVersion: '0.3.0',
        hosts: [
          ManagedHost(
            name: 'work',
            status: AppServeStatus(
              name: 'work',
              device: device,
              alive: true,
              appServiceKey: 'pcx:$device:app:work',
              incarnation: 'inc-${identity.id}',
            ),
            config: HostConfig(
              revision: 1,
              runtime: const HostRuntime.codex(),
              active: HostActive(
                incarnation: 'inc-${identity.id}',
                runtime: const HostRuntime.codex(),
                revision: 1,
              ),
            ),
          ),
        ],
      );
    }
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    Finder inTile(int i, Finder text) => find.descendant(
      of: find.byKey(Key('device-${devices[i]}')),
      matching: text,
    );
    expect(inTile(0, find.text('studio (Windows)')), findsOneWidget);
    expect(inTile(1, find.text('studio (WSL Ubuntu)')), findsOneWidget);
    expect(inTile(2, find.text('studio (WSL Debian)')), findsOneWidget);
    expect(inTile(3, find.text('studio (WSL Ubuntu)')), findsOneWidget);
    // Only the two copies of one distribution need their IDs to differ.
    expect(inTile(1, find.textContaining('22222222')), findsOneWidget);
    expect(inTile(3, find.textContaining('44444444')), findsOneWidget);
    expect(inTile(0, find.textContaining('11111111')), findsNothing);
    expect(inTile(2, find.textContaining('33333333')), findsNothing);
    for (var i = 0; i < devices.length; i++) {
      await tapKey(t, 'device-${devices[i]}');
      final metadata = api.managedDevices[managers[i]]!.metadata!;
      expect(_platform(t), metadata.instanceLabel);
      expect(metadata.instanceLabel, endsWith(identities[i].id));
      expect(find.byKey(Key('managed-device-${devices[i]}')), findsOneWidget);
      expect(find.byKey(const Key('add-local-host-card')), findsNothing);
    }
    await tapKey(t, 'device-${devices[1]}');
    await tapKey(t, 'managed-stop-work');
    await tapKey(t, 'managed-confirm-ok');
    final stop = api.managedCalls.single;
    expect(
      (stop.op, stop.key, stop.arg),
      ('stop', managers[1], 'inc-22222222'),
    );
    for (final other in [0, 2, 3]) {
      expect(
        api.managedDevices[managers[other]]!.hosts.single.status!.alive,
        isTrue,
      );
    }
    expect(t.takeException(), isNull);
  }, variant: windows);
}
