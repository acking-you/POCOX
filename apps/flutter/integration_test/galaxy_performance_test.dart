// Opt-in frame-time benchmark of the galaxy (`/galaxy`) on a desktop, with
// synthetic devices and services (no relay, host or model). Run in profile
// mode so the numbers mean something:
//
//   fvm flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/galaxy_performance_test.dart \
//     --dart-define=POCOX_GALAXY_PERF=true
//
// Each scene animates for [_sample] after a warm-up and prints one
// `GALAXY_PERF {...}` line: UI-thread (build, which includes the painter) and
// raster durations in microseconds, as percentiles over every frame; the
// process's resident memory and the galaxy's sprite images at the end; and
// the sample's wall-clock window, to line up an outside sampler such as
// `footprint`, which also counts the GPU memory resident memory leaves out.
// The window stays on top of the main display while it runs: macOS stops
// drawing a covered window, which would leave a scene with a handful of
// frames, and another display may have another pixel ratio and refresh
// rate.
import 'dart:convert';
import 'dart:io' show ProcessInfo;
import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/tools/galaxy/galaxy_frame.dart';
import 'package:pocox/src/tools/galaxy/galaxy_screen.dart';
import 'package:pocox/src/tools/galaxy/galaxy_sprites.dart';
import 'package:window_manager/window_manager.dart';

import '../test/fake_bridge_api.dart';

const _warmUp = Duration(seconds: 3);
const _sample = Duration(seconds: 8);

ToolsService _service(
  String device,
  String kind,
  String name, {
  String? agent,
}) => ToolsService(
  key: 'pcx:$device:${kind == 'agent' ? 'app' : kind}:$name',
  kind: kind,
  name: name,
  status: name.hashCode.isEven ? 'online' : 'starting',
  agent: agent,
  title: kind == 'port' ? 'Preview $name' : null,
  port: kind == 'port' ? int.parse(name) : null,
);

/// [devices] devices, this one first, each with two agents, an API and
/// [ports] shared ports; this device connects to the first API of every
/// fourth device.
ToolsOverview _overview(int devices, int ports) {
  final names = [
    for (var i = 0; i < devices; i++) i == 0 ? 'studio' : 'node-$i',
  ];
  return ToolsOverview(
    thisDevice: 'studio',
    devices: [
      for (final (i, name) in names.indexed)
        ToolsDevice(
          name: name,
          platform: i.isEven ? 'macos' : 'linux',
          online: i % 7 != 6,
          catalog: true,
          toolsEnabled: true,
          services: [
            _service(name, 'agent', 'default', agent: 'codex'),
            _service(name, 'agent', 'claude', agent: 'claude'),
            _service(name, 'api', 'default'),
            for (var p = 0; p < ports; p++)
              _service(name, 'port', '${3000 + p}'),
          ],
        ),
    ],
    connections: [
      for (var i = 1; i < devices; i += 4)
        ToolsConnection(
          service: 'pcx:${names[i]}:api:default',
          local: '127.0.0.1:${18000 + i}',
          samePort: false,
          owner: const ToolsOwner(kind: 'user', label: 'This device'),
        ),
    ],
  );
}

Widget _app(FakeBridgeApi api, {required bool dark}) => ProviderScope(
  overrides: [bridgeApiProvider.overrideWithValue(api)],
  child: MaterialApp.router(
    theme: lightTheme(),
    darkTheme: darkTheme(),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    routerConfig: GoRouter(
      initialLocation: '/galaxy',
      routes: [
        GoRoute(path: '/galaxy', builder: (_, _) => const GalaxyScreen()),
      ],
    ),
  ),
);

Map<String, num> _stats(List<int> micros) {
  if (micros.isEmpty) return const {};
  final sorted = [...micros]..sort();
  int at(double q) => sorted[((sorted.length - 1) * q).round()];
  return {
    'avg': (micros.reduce((a, b) => a + b) / micros.length).round(),
    'p50': at(0.5),
    'p90': at(0.9),
    'p99': at(0.99),
    'max': sorted.last,
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const enabled = bool.fromEnvironment('POCOX_GALAXY_PERF');
  if (enabled) {
    setUpAll(() async {
      await windowManager.ensureInitialized();
      await windowManager.setPosition(const Offset(80, 80));
      await windowManager.setAlwaysOnTop(true);
    });
  }

  for (final (scene, devices, ports) in [('typical', 5, 2), ('busy', 24, 5)]) {
    for (final dark in [true, false]) {
      final name = '$scene-${dark ? 'dark' : 'light'}';
      testWidgets('galaxy frame times: $name', (tester) async {
        if (!enabled) {
          markTestSkipped('set POCOX_GALAXY_PERF=true to run');
          return;
        }
        final api = FakeBridgeApi()
          ..toolsOverviewValue = _overview(devices, ports);
        await tester.pumpWidget(_app(api, dark: dark));
        await tester.pump(_warmUp);
        final timings = <FrameTiming>[];
        void collect(List<FrameTiming> batch) => timings.addAll(batch);
        SchedulerBinding.instance.addTimingsCallback(collect);
        final started = DateTime.now().millisecondsSinceEpoch;
        await tester.pump(_sample);
        // Timings arrive in batches; let the last one in.
        await tester.pump(const Duration(milliseconds: 300));
        SchedulerBinding.instance.removeTimingsCallback(collect);
        final ended = DateTime.now().millisecondsSinceEpoch;
        final size = tester.view.physicalSize / tester.view.devicePixelRatio;
        final result = {
          'scene': name,
          'devices': devices,
          'services': devices * (3 + ports),
          'size': '${size.width.round()}x${size.height.round()}',
          'ratio': tester.view.devicePixelRatio,
          'frames': timings.length,
          // Whether the frame geometry came from Rust or the Dart port.
          'native': GalaxyNative.available,
          'build_us': _stats([
            for (final t in timings) t.buildDuration.inMicroseconds,
          ]),
          'raster_us': _stats([
            for (final t in timings) t.rasterDuration.inMicroseconds,
          ]),
          'rss_mb': (ProcessInfo.currentRss / (1 << 20)).round(),
          'sprite_kb': GalaxySprites.liveBytes >> 10,
          'window_ms': [started, ended],
        };
        debugPrint('GALAXY_PERF ${jsonEncode(result)}');
        expect(timings, isNotEmpty);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
