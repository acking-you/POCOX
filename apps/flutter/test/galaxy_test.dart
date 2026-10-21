import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/tools/galaxy/galaxy_screen.dart';
import 'package:pocox/src/tools/galaxy/galaxy_view.dart';
import 'package:pocox/src/widgets/glass.dart';

import 'fake_bridge_api.dart';
import 'support/ui_preview.dart';

ToolsService _service(
  String device,
  String kind,
  String name, {
  String status = 'online',
  String? agent,
  String? title,
  String? owner,
  String? share,
}) => ToolsService(
  key:
      'pcx:$device:${kind == 'agent' ? (agent == 'codex'
                ? 'app'
                : agent == 'opencode'
                ? 'opencode'
                : 'acp') : kind}:$name',
  kind: kind,
  name: name,
  status: status,
  agent: agent,
  title: title,
  port: kind == 'port' ? int.parse(name) : null,
  owner: owner,
  share: share,
);

/// Four devices: this Mac with agents, an API and two shares, a Linux box,
/// a second workstation starting up, and an offline NAS.
ToolsOverview fixture() {
  final now = DateTime.now().millisecondsSinceEpoch;
  const codex = ToolsOwner(
    kind: 'agent',
    label: 'Codex · default',
    harness: 'codex',
    host: 'default',
    conversation: 'thread-1',
  );
  final landing = ToolsShare(
    id: 's1',
    title: 'Landing page',
    path: '/',
    ports: const [
      ToolsPort(port: 5173, key: 'pcx:studio:port:5173', status: 'online'),
    ],
    owner: codex,
    createdMs: now - 600000,
    expiresMs: now + 20 * 3600000,
  );
  const docs = ToolsShare(
    id: 's2',
    title: 'Docs preview',
    path: '/docs',
    ports: [
      ToolsPort(port: 8000, key: 'pcx:studio:port:8000', status: 'online'),
    ],
    owner: ToolsOwner(kind: 'user', label: 'You'),
    createdMs: 0,
  );
  return ToolsOverview(
    thisDevice: 'studio',
    devices: [
      ToolsDevice(
        name: 'studio',
        platform: 'macos',
        online: true,
        catalog: true,
        toolsEnabled: true,
        services: [
          _service('studio', 'agent', 'default', agent: 'codex'),
          _service('studio', 'agent', 'claude', agent: 'claude'),
          _service('studio', 'api', 'default'),
          _service(
            'studio',
            'port',
            '5173',
            title: 'Landing page',
            owner: 'Codex · default',
            share: 's1',
          ),
          _service(
            'studio',
            'port',
            '8000',
            title: 'Docs preview',
            owner: 'You',
            share: 's2',
          ),
        ],
        shares: [landing, docs],
      ),
      ToolsDevice(
        name: 'devbox',
        platform: 'linux',
        online: true,
        catalog: true,
        toolsEnabled: true,
        services: [
          _service('devbox', 'agent', 'opencode', agent: 'opencode'),
          _service('devbox', 'api', 'default'),
          _service(
            'devbox',
            'port',
            '3000',
            status: 'unreachable',
            title: 'Orders API',
          ),
        ],
      ),
      ToolsDevice(
        name: 'gpu-rig',
        platform: 'linux',
        online: true,
        catalog: true,
        services: [
          _service(
            'gpu-rig',
            'agent',
            'default',
            agent: 'codex',
            status: 'starting',
          ),
        ],
      ),
      const ToolsDevice(name: 'nas', online: false, catalog: false),
    ],
    connections: const [
      ToolsConnection(
        service: 'pcx:devbox:api:default',
        local: '127.0.0.1:18180',
        samePort: true,
        owner: ToolsOwner(kind: 'user', label: 'This device'),
      ),
    ],
  );
}

Widget _app(
  FakeBridgeApi api, {
  required bool dark,
  Size size = const Size(1440, 900),
  bool still = false,
}) => ProviderScope(
  overrides: [bridgeApiProvider.overrideWithValue(api)],
  child: MaterialApp.router(
    theme: lightTheme(),
    darkTheme: darkTheme(),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: still),
      child: child!,
    ),
    routerConfig: GoRouter(
      initialLocation: '/galaxy',
      routes: [
        GoRoute(
          path: '/galaxy',
          builder: (_, _) =>
              const RepaintBoundary(key: previewKey, child: GalaxyScreen()),
        ),
        GoRoute(path: '/manage', builder: (_, _) => const Text('manage')),
      ],
    ),
  ),
);

void main() {
  setUpAll(loadPreviewFonts);

  for (final dark in [false, true]) {
    testWidgets(
      'every device and service is in the galaxy and opens (${dark ? 'dark' : 'light'})',
      (t) async {
        t.view.physicalSize = const Size(1440, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final api = FakeBridgeApi()..toolsOverviewValue = fixture();
        await t.pumpWidget(_app(api, dark: dark));
        // Let the camera settle into its framing.
        for (var i = 0; i < 40; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        await capturePreview(t, 'galaxy-${dark ? 'dark' : 'light'}');
        // The list names every service; picking one opens its details.
        await t.tap(find.byKey(const Key('galaxy-list-toggle')));
        await t.pump();
        expect(find.text('Landing page'), findsWidgets);
        // The search narrows what is shared too, not just the systems.
        await t.enterText(find.byKey(const Key('galaxy-search')), 'zzz');
        await t.pump();
        expect(find.text('Landing page'), findsNothing);
        await t.enterText(find.byKey(const Key('galaxy-search')), '');
        await t.pump();
        await t.tap(
          find.byKey(const Key('galaxy-list-pcx:studio:app:default')),
        );
        for (var i = 0; i < 10; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        expect(find.byKey(const Key('galaxy-panel-close')), findsOneWidget);
        expect(find.text('Open conversations'), findsOneWidget);
        await capturePreview(t, 'galaxy-panel-${dark ? 'dark' : 'light'}');
        await t.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('a phone frames the galaxy and its panel without overflow', (
    t,
  ) async {
    t.view.physicalSize = const Size(393 * 3, 852 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final api = FakeBridgeApi()..toolsOverviewValue = fixture();
    await t.pumpWidget(_app(api, dark: true, size: const Size(393, 852)));
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await capturePreview(t, 'galaxy-phone');
    // The list starts below the search bar, which takes two rows here.
    await t.tap(find.byKey(const Key('galaxy-list-toggle')));
    await t.pump();
    await t.pump();
    final bar = t.getRect(
      find
          .ancestor(
            of: find.byKey(const Key('galaxy-search')),
            matching: find.byType(Glass),
          )
          .first,
    );
    expect(
      t.getRect(find.text('Shared with you')).top,
      greaterThanOrEqualTo(bar.bottom),
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a still galaxy stops drawing once its camera rests, also on a '
      'selected planet, and wakes for input', (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final api = FakeBridgeApi()..toolsOverviewValue = fixture();
    await t.pumpWidget(_app(api, dark: false, still: true));
    Future<void> rest() async {
      for (var i = 0; i < 80 && t.binding.hasScheduledFrame; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    await rest();
    expect(t.binding.hasScheduledFrame, isFalse);
    // A planet stands still where it is drawn, so the camera reaches it.
    await t.tap(find.byKey(const Key('galaxy-list-toggle')));
    await t.pump();
    await t.tap(find.byKey(const Key('galaxy-list-pcx:studio:app:default')));
    await t.pump();
    expect(t.binding.hasScheduledFrame, isTrue);
    await rest();
    expect(find.byKey(const Key('galaxy-panel-close')), findsOneWidget);
    expect(t.binding.hasScheduledFrame, isFalse);
    await t.pumpWidget(const SizedBox());
  });

  test('a body drawn under the pointer wins over a star\'s reach', () {
    final view = GalaxyView()
      ..hits = const [
        Hit('device:studio', Offset(100, 100), 16, 5, 'studio'),
        Hit('pcx:studio:port:5173', Offset(124, 100), 6, 9, 'Landing page'),
      ];
    expect(view.hitAt(const Offset(124, 100))?.id, 'pcx:studio:port:5173');
    expect(view.hitAt(const Offset(104, 100))?.id, 'device:studio');
    // Beside both: the nearest within reach.
    expect(view.hitAt(const Offset(124, 116))?.id, 'pcx:studio:port:5173');
    view.dispose();
  });
}
