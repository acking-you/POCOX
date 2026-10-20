// The galaxy's frames come from Rust in the app and from the Dart port in
// tests; this compares the two on the built bridge library. Opt-in:
//
//   PCX_BRIDGE_LIBRARY=<path to libpocket_codex_bridge.{dylib,so} or .dll> \
//     fvm flutter test test/galaxy_frame_parity_test.dart
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_backdrop.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_frame.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_model.dart';

import 'galaxy_test.dart' show fixture;

/// [fixture] plus [extra] more devices with agents, an API and ports.
ToolsOverview _overview(int extra) {
  final base = fixture();
  ToolsService service(String device, String kind, String name) => ToolsService(
    key: 'pcx:$device:$kind:$name',
    kind: kind,
    name: name,
    status: 'online',
    agent: kind == 'agent' ? 'codex' : null,
    port: kind == 'port' ? int.parse(name) : null,
  );
  return ToolsOverview(
    thisDevice: base.thisDevice,
    devices: [
      ...base.devices,
      for (var i = 0; i < extra; i++)
        ToolsDevice(
          name: 'node-$i',
          online: i % 5 != 4,
          catalog: true,
          services: [
            service('node-$i', 'agent', 'default'),
            service('node-$i', 'api', 'default'),
            for (var p = 0; p < i % 9; p++)
              service('node-$i', 'port', '${3000 + p}'),
          ],
        ),
    ],
    connections: base.connections,
  );
}

void main() {
  final path = Platform.environment['PCX_BRIDGE_LIBRARY'];

  test('Rust and Dart compute the same galaxy frames', () {
    if (path == null) {
      markTestSkipped('set PCX_BRIDGE_LIBRARY to the built bridge library');
      return;
    }
    final scene = buildScene(_overview(14));
    final bodies = GalaxyBodies(scene);
    final first = bodies.planets.first.id;
    final encoded = encodeScene(
      bodies,
      stars: Starfield().data,
      deviceLabel: (system) => Size(system.device.name.length * 7.0, 15),
      planetLabel: (planet, {required strong}) =>
          Size(planet.id.length * (strong ? 6.5 : 6.0), strong ? 15 : 14),
      // One body still spiralling out and one rippling at time 7.3.
      appeared: {first: 6.5},
      rippled: {bodies.planets.last.id: 7.0},
    );
    final cameras = [
      for (final (yaw, tilt, distance) in [
        (0.6, 0.52, 12.0),
        (2.3, 0.16, 6.0),
        (4.1, 1.3, 30.0),
        (-1.0, 0.82, 2.2),
      ])
        for (final (size, time, still, selected) in [
          (const Size(1440, 900), 7.3, false, -1),
          (const Size(393, 852), 120.25, false, bodies.systems.length),
          (const Size(1100, 700), 0.0, true, 0),
          (const Size(1440, 900), 33.0, false, -2),
        ])
          (yaw, tilt, distance, size, time, still, selected),
    ];
    GalaxyNative.use(DynamicLibrary.open(path));
    addTearDown(GalaxyNative.reset);
    final native = GalaxyFrameBuffer();
    addTearDown(native.dispose);
    for (final (yaw, tilt, distance, size, time, still, selected) in cameras) {
      void frame(Float64List into) => encodeFrame(
        into,
        size: size,
        yaw: yaw,
        tilt: tilt,
        distance: distance,
        target: selected >= 0 && selected < bodies.systems.length
            ? bodies.systems[selected].position
            : Vec3.zero,
        time: time,
        still: still,
        selected: selected,
        hovered: bodies.systems.length + 2,
        focused: -1,
      );
      frame(native.frame);
      final fromRust = Float32List.fromList(native.compute(encoded)!);
      final fromDart = Float32List(fromRust.length + 64);
      final frameValues = Float64List(galaxyFrameFields);
      frame(frameValues);
      final written = computeFrameInDart(encoded, frameValues, fromDart);
      final where = 'yaw $yaw tilt $tilt distance $distance $size t $time';
      expect(written, fromRust.length, reason: where);
      for (var i = 0; i < written; i++) {
        final (r, d) = (fromRust[i], fromDart[i]);
        expect(
          (r - d).abs() <= 1e-3 * (1 + r.abs()),
          isTrue,
          reason: '$where: value $i is $r in Rust, $d in Dart',
        );
      }
    }
  });
}
