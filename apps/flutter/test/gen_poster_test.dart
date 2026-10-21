// Derives the README poster from the app itself, rendered with the bundled
// fonts and fixture data (no real session): the galaxy of every device and
// the services it shares; behind it, POCOX's Local sessions view of every
// session its agents' own apps run; on the phone, an agent that started a
// dev server and shared it with the user's other devices through POCOX's
// built-in tools. Beside them: the mark, the POCOX wordmark (spelled out of
// "POcket COdeX") and the agents and services a pocket reaches.
//
// Opt-in like gen_icon_test (PNG output differs across platforms):
//   REGEN_ICONS=1 fvm flutter test test/gen_poster_test.dart
//
// Outputs (both copies kept identical, at twice the layout size):
//   assets/logo/poster.png, apps/flutter/assets/logo/poster.png
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/screens/app_session_screen.dart';
import 'package:pocox/src/screens/local_sessions_screen.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/tools/galaxy/galaxy_screen.dart';
import 'package:pocox/src/widgets/agent_icon.dart';

import 'fake_bridge_api.dart';
import 'gen_icon_test.dart' show renderMark;
import 'support/ui_preview.dart';

const _codex = 'pcx:studio:app:default';
const _cwd = '/Users/me/work/atlas';

/// The poster's layout size; it is written at [_outputScale] times this.
const _poster = Size(1536, 1024);
const _outputScale = 2.0;

/// Screens are captured at twice their logical size, so they stay sharp once
/// placed in the poster.
const _captureScale = 2.0;

// The theme's own tokens (theme.dart): ink, the neutral surface, muted text
// and the one signal blue.
const _ink = Color(0xFF1D1D1F);
const _muted = Color(0xFF4A4A4D);
const _faint = Color(0xFFB4B4B2);
const _signal = Color(0xFF2A52C4);
const _surface = Color(0xFFFBFBFA);
const _hairline = Color(0xFFE4E4E2);

int _ago(Duration d) =>
    DateTime.now().subtract(d).millisecondsSinceEpoch ~/ 1000;

/// The session Codex's own app holds, as both screens show it.
const _held = 'Speed up the Windows build';

/// Sessions the agents' own apps and CLIs ran on this computer.
List<LocalSession> _sessions() {
  LocalSession row(
    String id,
    String title,
    String source,
    Duration ago, {
    String safety = 'resumable',
    bool held = false,
    bool resume = true,
    bool takeover = false,
    String? status,
  }) => LocalSession(
    threadId: id,
    cwd: _cwd,
    preview: title,
    name: title,
    status: status,
    source: source,
    updatedAt: _ago(ago),
    turnState: safety == 'ownedRunning' ? 'incomplete' : 'completed',
    heldOpen: held,
    safety: safety,
    allowsResume: resume,
    requiresTakeover: takeover,
  );
  return [
    row(
      's1',
      'Refactor the sync engine',
      'vscode',
      Duration.zero,
      safety: 'ownedRunning',
      held: true,
      resume: false,
    ),
    row(
      's2',
      'Profile the import pipeline',
      'cli',
      const Duration(minutes: 2),
      safety: 'ownedRunning',
      held: true,
      status: 'active',
    ),
    row(
      't1',
      _held,
      'vscode',
      const Duration(minutes: 9),
      safety: 'ownedIdle',
      held: true,
      takeover: true,
    ),
    row(
      's4',
      'Tidy the settings page on phones',
      'appServer',
      const Duration(hours: 3),
    ),
    row('s5', 'Draft the release notes', 'cli', const Duration(hours: 6)),
    row('s6', 'Why is the nightly build red?', 'exec', const Duration(days: 1)),
    row('s7', 'Explain the relay handshake', 'vscode', const Duration(days: 2)),
  ];
}

Future<FakeBridgeApi> _api() async {
  final api =
      FakeBridgeApi(
          config: const ConfigInfo(
            relay: 'relay.example.com:7666',
            hasKey: true,
          ),
          services: const [
            ServiceEntry(
              device: 'studio',
              kind: 'app',
              name: 'default',
              key: _codex,
            ),
          ],
        )
        ..appThreads.add(
          ThreadMeta(
            id: 't1',
            preview: _held,
            name: _held,
            cwd: _cwd,
            updatedAt: _ago(const Duration(minutes: 9)),
          ),
        )
        ..localSessions = _sessions()
        // Codex's own app still holds the session: the phone follows it.
        ..appThreadResumeError = StateError(
          'thread already has an active writer',
        )
        ..metadataOnlyFollow = true
        ..liveness['t1'] = const SessionLiveness(
          threadId: 't1',
          turnState: 'completed',
          heldOpen: true,
          safety: 'ownedIdle',
          allowsResume: true,
          requiresTakeover: true,
          holders: [],
        )
        ..readResult = _heldHistory;
  await api.appConnect(_codex, 1);
  return api;
}

const _heldHistory = ThreadHistory(
  running: false,
  branch: 'ci-cache',
  cwd: _cwd,
  items: [
    ThreadItem(
      id: 'u0',
      itemType: 'userMessage',
      title: '',
      text: 'Why is the Windows build so much slower than macOS?',
      turnId: 'turn0',
    ),
    ThreadItem(
      id: 'a0',
      itemType: 'agentMessage',
      title: '',
      text:
          'Its runner rebuilds `zstd-sys` and `ring` from scratch on every '
          'push; macOS restores them from cache.',
      turnId: 'turn0',
      turnDurationMs: 41000,
    ),
    ThreadItem(
      id: 'u1',
      itemType: 'userMessage',
      title: '',
      text: 'Cache them per toolchain and check the timings.',
      turnId: 'turn1',
    ),
    ThreadItem(
      id: 'c1',
      itemType: 'commandExecution',
      title: 'gh run list --workflow ci.yml --limit 5',
      text: 'completed  success  windows  5m02s',
      turnId: 'turn1',
      turnDurationMs: 128000,
    ),
    ThreadItem(
      id: 'a1',
      itemType: 'agentMessage',
      title: '',
      text:
          'Done:\n\n'
          '- `target/` is cached per toolchain and lockfile\n'
          '- the Windows job takes **5 min** instead of 14\n'
          '- cold runs still rebuild everything, as before',
      turnId: 'turn1',
      turnDurationMs: 128000,
    ),
  ],
);

/// The phone's conversation: the agent starts the landing page and shares it.
const _shareThread = 'p1';
const _sharePrompt = 'Start the landing page and put it on my phone.';
const _landing = 'pcx:studio:port:5173';

const _shareHistory = ThreadHistory(
  running: false,
  branch: 'landing',
  cwd: _cwd,
  items: [
    ThreadItem(
      id: 'u0',
      itemType: 'userMessage',
      title: '',
      text: _sharePrompt,
      turnId: 'turn0',
    ),
    ThreadItem(
      id: 'c0',
      itemType: 'commandExecution',
      title: 'npm run dev -- --port 5173',
      text: 'VITE ready in 412 ms\n  Local: http://localhost:5173/',
      turnId: 'turn0',
      turnDurationMs: 23000,
    ),
    ThreadItem(
      id: 'm0',
      itemType: 'mcpToolCall',
      title: 'pocox.connect',
      text:
          '{"result":{"structuredContent":{"status":"shared","service":'
          '"$_landing","share":{"id":"s1","title":"Landing page","path":"/",'
          '"ports":[{"port":5173}]}},"content":[{"type":"text","text":'
          '"Shared: pocox://open?service=$_landing&path=/"}]}}',
      turnId: 'turn0',
      turnDurationMs: 23000,
    ),
    ThreadItem(
      id: 'a0',
      itemType: 'agentMessage',
      title: '',
      text:
          'The landing page runs on **studio** and is shared with your '
          'devices: open it from the card. It stays up for a day, or until '
          'you stop it.',
      turnId: 'turn0',
      turnDurationMs: 23000,
    ),
  ],
);

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
      'pcx:$device:${kind == 'agent' ? switch (agent) {
              'codex' => 'app',
              'opencode' => 'opencode',
              _ => 'acp',
            } : kind}:$name',
  kind: kind,
  name: name,
  status: status,
  agent: agent,
  title: title,
  port: kind == 'port' ? int.parse(name) : null,
  owner: owner,
  share: share,
);

/// Every device the user has, with its agents, APIs and shared ports, as
/// [thisDevice] sees them.
ToolsOverview _galaxy({String thisDevice = 'studio'}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  const codex = ToolsOwner(
    kind: 'agent',
    label: 'Codex · default',
    harness: 'codex',
    host: 'default',
    conversation: _shareThread,
  );
  final landing = ToolsShare(
    id: 's1',
    title: 'Landing page',
    path: '/',
    ports: const [ToolsPort(port: 5173, key: _landing, status: 'online')],
    owner: codex,
    createdMs: now - 60000,
    expiresMs: now + 24 * 3600000,
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
  const board = ToolsShare(
    id: 's3',
    title: 'Training board',
    path: '/',
    ports: [
      ToolsPort(port: 6006, key: 'pcx:gpu-rig:port:6006', status: 'online'),
    ],
    owner: ToolsOwner(kind: 'agent', label: 'Grok · grok', harness: 'grok'),
    createdMs: 0,
  );
  return ToolsOverview(
    thisDevice: thisDevice,
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
          _service('studio', 'agent', 'grok', agent: 'grok'),
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
          _service('devbox', 'agent', 'grok', agent: 'grok'),
          _service('devbox', 'api', 'default'),
          _service('devbox', 'port', '3000', title: 'Orders API'),
        ],
      ),
      ToolsDevice(
        name: 'gpu-rig',
        platform: 'linux',
        online: true,
        catalog: true,
        toolsEnabled: true,
        services: [
          _service('gpu-rig', 'agent', 'default', agent: 'codex'),
          _service(
            'gpu-rig',
            'port',
            '6006',
            title: 'Training board',
            owner: 'Grok · grok',
            share: 's3',
          ),
        ],
        shares: const [board],
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
      ToolsConnection(
        service: 'pcx:gpu-rig:port:6006',
        local: '127.0.0.1:6006',
        samePort: true,
        owner: ToolsOwner(kind: 'user', label: 'This device'),
      ),
    ],
  );
}

/// The phone: one conversation on the computer's Codex host, with the
/// computer's shares known to it.
Future<FakeBridgeApi> _phoneApi() async {
  final api =
      FakeBridgeApi(
          config: const ConfigInfo(
            relay: 'relay.example.com:7666',
            hasKey: true,
          ),
          services: const [
            ServiceEntry(
              device: 'studio',
              kind: 'app',
              name: 'default',
              key: _codex,
            ),
          ],
        )
        ..appThreads.add(
          ThreadMeta(
            id: _shareThread,
            preview: _sharePrompt,
            name: 'Put the landing page on my phone',
            cwd: _cwd,
            updatedAt: _ago(const Duration(minutes: 1)),
          ),
        )
        ..readResult = _shareHistory
        ..toolsOverviewValue = _galaxy(thisDevice: 'iphone');
  await api.appConnect(_codex, 1);
  return api;
}

/// Bounded pumps: connection probes and spinners never settle.
Future<void> _frames(WidgetTester t, [int count = 10]) async {
  for (var i = 0; i < count; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// [child] rendered on [platform] at [size] (logical pixels).
Future<ui.Image> _shot(
  WidgetTester t, {
  required TargetPlatform platform,
  required Size size,
  required Widget child,
  FakeBridgeApi? api,
  EdgeInsets safeArea = EdgeInsets.zero,
  bool dark = false,
  int frames = 10,
  Future<void> Function(WidgetTester t)? arrange,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size;
    t.view.padding = t.view.viewPadding = FakeViewPadding(
      top: safeArea.top,
      bottom: safeArea.bottom,
    );
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          bridgeApiProvider.overrideWithValue(api ?? FakeBridgeApi()),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('en'),
          theme: dark ? darkTheme() : lightTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, navigator) =>
              RepaintBoundary(key: previewKey, child: navigator!),
          home: child,
        ),
      ),
    );
    await _frames(t, frames);
    if (arrange != null) {
      await arrange(t);
      await _frames(t, frames);
    }
    final boundary = t.renderObject<RenderRepaintBoundary>(
      find.byKey(previewKey),
    );
    final image = await t.runAsync(
      () => boundary.toImage(pixelRatio: _captureScale),
    );
    await t.pumpWidget(const SizedBox());
    await _frames(t, 2);
    return image!;
  } finally {
    debugDefaultTargetPlatformOverride = null;
    t.view.reset();
  }
}

/// The agents and services a pocket reaches, as chips with their real marks.
Widget _services() {
  Widget chip(Widget mark, String label) => Container(
    height: 34,
    padding: const EdgeInsets.symmetric(horizontal: 11),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(17),
      border: Border.all(color: _hairline),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: 7),
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'GoogleSansFlex',
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: _ink,
          ),
        ),
      ],
    ),
  );
  return Material(
    type: MaterialType.transparency,
    child: Align(
      alignment: Alignment.topLeft,
      child: Wrap(
        spacing: 7,
        runSpacing: 7,
        children: [
          chip(const AgentIcon(kind: AgentKind.codex, size: 15), 'Codex'),
          chip(const AgentIcon(kind: AgentKind.claude, size: 15), 'Claude'),
          chip(const AgentIcon(kind: AgentKind.opencode, size: 15), 'OpenCode'),
          chip(const AgentIcon(kind: AgentKind.grok, size: 15), 'Grok Build'),
          chip(
            const Icon(Icons.api_rounded, size: 15, color: _signal),
            'Responses API',
          ),
        ],
      ),
    ),
  );
}

ui.Paragraph _text(
  List<(String, Color)> runs, {
  required double size,
  FontWeight weight = FontWeight.w400,
  double width = 1000,
  double height = 1.15,
  double spacing = 0,
}) {
  final builder = ui.ParagraphBuilder(
    ui.ParagraphStyle(fontFamily: 'GoogleSansFlex', height: height),
  );
  for (final (text, color) in runs) {
    builder.pushStyle(
      ui.TextStyle(
        color: color,
        fontSize: size,
        fontWeight: weight,
        fontFamily: 'GoogleSansFlex',
        letterSpacing: spacing,
        height: height,
      ),
    );
    builder.addText(text);
    builder.pop();
  }
  return builder.build()..layout(ui.ParagraphConstraints(width: width));
}

/// A soft, outer-only shadow under [shape].
void _shadow(Canvas canvas, RRect shape, {double blur = 40, double y = 24}) {
  canvas.drawRRect(
    shape.shift(Offset(0, y)),
    Paint()
      ..color = const Color(0x24000000)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
  );
  canvas.drawRRect(
    shape.shift(const Offset(0, 2)),
    Paint()
      ..color = const Color(0x14000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
  );
}

void _image(Canvas canvas, ui.Image image, Rect into, [RRect? clip]) {
  canvas.save();
  if (clip != null) canvas.clipRRect(clip);
  canvas.drawImageRect(
    image,
    Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
    into,
    Paint()..filterQuality = FilterQuality.high,
  );
  canvas.restore();
}

/// The desktop window: the captured screen with macOS window controls in its
/// title strip and a hairline edge.
void _window(Canvas canvas, ui.Image screen, Rect at) {
  final shape = RRect.fromRectAndRadius(at, const Radius.circular(14));
  _shadow(canvas, shape, blur: 48, y: 28);
  _image(canvas, screen, at, shape);
  final scale = at.width / (screen.width / _captureScale);
  // Traffic lights sit centred in the 60 pt title strip.
  const colors = [Color(0xFFFF5F57), Color(0xFFFEBC2E), Color(0xFF28C840)];
  for (final (i, color) in colors.indexed) {
    canvas.drawCircle(
      at.topLeft + Offset((20 + i * 20) * scale, 30 * scale),
      6 * scale,
      Paint()..color = color,
    );
  }
  canvas.drawRRect(
    shape,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x1F000000),
  );
}

/// The phone: the captured screen in an ink frame, with a status bar around
/// its island.
void _phone(Canvas canvas, ui.Image screen, Rect at) {
  const bezel = 9.0;
  final frame = RRect.fromRectAndRadius(at, const Radius.circular(44));
  _shadow(canvas, frame, blur: 44, y: 26);
  canvas.drawRRect(frame, Paint()..color = _ink);
  final inner = RRect.fromRectAndRadius(
    at.deflate(bezel),
    const Radius.circular(44 - bezel),
  );
  _image(canvas, screen, inner.outerRect, inner);
  final island = Rect.fromCenter(
    center: Offset(at.center.dx, at.top + bezel + 17),
    width: at.width * 0.3,
    height: 22,
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(island, const Radius.circular(11)),
    Paint()..color = _ink,
  );
  final clock = _text([('9:41', _ink)], size: 13, weight: FontWeight.w600);
  canvas.drawParagraph(
    clock,
    Offset(at.left + bezel + 26, island.center.dy - clock.height / 2),
  );
  final battery = Rect.fromCenter(
    center: Offset(at.right - bezel - 32, island.center.dy),
    width: 22,
    height: 11,
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(battery, const Radius.circular(3)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = _ink,
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(battery.deflate(2.4), const Radius.circular(1.5)),
    Paint()..color = _ink,
  );
}

Future<ui.Image> _compose({
  required ui.Image galaxy,
  required ui.Image sessions,
  required ui.Image phone,
  required ui.Image services,
  required ui.Image mark,
}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(_outputScale);
  final bounds = Offset.zero & _poster;
  // The app's backdrop: neutral, lit only by white.
  canvas.drawRect(
    bounds,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(0, _poster.height),
        const [_surface, Color(0xFFEFEFED)],
      ),
  );
  canvas.drawRect(
    bounds,
    Paint()
      ..shader = ui.Gradient.radial(const Offset(320, 300), 720, const [
        Color(0xCCFFFFFF),
        Color(0x00FFFFFF),
      ]),
  );

  const left = 96.0;
  _image(canvas, mark, const Rect.fromLTWH(left - 4, 92, 92, 92));
  canvas.drawParagraph(
    _text([('POCOX', _ink)], size: 112, weight: FontWeight.w700, spacing: -2.4),
    const Offset(left - 6, 194),
  );
  // The name, spelled out of the words it comes from.
  canvas.drawParagraph(
    _text(
      [
        ('PO', _signal),
        ('cket ', _faint),
        ('CO', _signal),
        ('de', _faint),
        ('X', _signal),
      ],
      size: 38,
      weight: FontWeight.w600,
      spacing: 1,
    ),
    const Offset(left, 330),
  );
  canvas.drawParagraph(
    _text(
      [('Every device,\nin your pocket.', _ink)],
      size: 44,
      weight: FontWeight.w600,
      height: 1.14,
      spacing: -0.6,
      width: 460,
    ),
    const Offset(left, 410),
  );
  canvas.drawParagraph(
    _text(
      [
        (
          'Keep using Codex, Claude Code, OpenCode and Grok Build the way '
              'their makers ship them. POCOX sees every session they run and '
              'lets you pick any of them up from another device.',
          _muted,
        ),
      ],
      size: 18,
      height: 1.5,
      width: 440,
    ),
    const Offset(left, 534),
  );
  // The second promise: any service, on every device, by agents too.
  canvas.drawParagraph(
    _text(
      [('Any service, on every device.', _ink)],
      size: 22,
      weight: FontWeight.w600,
      spacing: -0.2,
    ),
    const Offset(left, 666),
  );
  canvas.drawParagraph(
    _text(
      [
        (
          'Share a dev server, an API or an agent from one machine with all '
              'your others. Your agents do it on their own, with POCOX\'s '
              'built-in tools.',
          _muted,
        ),
      ],
      size: 18,
      height: 1.5,
      width: 440,
    ),
    const Offset(left, 702),
  );
  final chips = Size(
    services.width / _captureScale,
    services.height / _captureScale,
  );
  _image(canvas, services, const Offset(left, 816) & chips);
  canvas.drawParagraph(
    _text(
      [('iOS · Android · macOS · Windows · Linux', _faint)],
      size: 16,
      weight: FontWeight.w500,
      spacing: 0.2,
    ),
    Offset(left + 2, 816 + chips.height + 16),
  );

  // Behind: every session; in front: every device; on the phone: an agent's
  // share. Windows keep the 1040 × 720 screens' proportions.
  _window(canvas, sessions, const Rect.fromLTWH(890, 48, 600, 415.4));
  _window(canvas, galaxy, const Rect.fromLTWH(640, 270, 850, 588.5));
  _phone(canvas, phone, const Rect.fromLTWH(566, 372, 262, 568));
  return recorder.endRecording().toImage(
    (_poster.width * _outputScale).toInt(),
    (_poster.height * _outputScale).toInt(),
  );
}

void main() {
  // PNG output differs across platforms: regenerate only on request.
  final skip = Platform.environment['REGEN_ICONS'] != '1';

  setUpAll(() => loadPreviewFonts(always: true));
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('derive the README poster from the app', (t) async {
    final sessions = await _shot(
      t,
      platform: TargetPlatform.macOS,
      size: const Size(1040, 720),
      api: await _api(),
      child: const LocalSessionsScreen(),
    );
    final galaxy = await _shot(
      t,
      platform: TargetPlatform.macOS,
      size: const Size(1040, 720),
      api: FakeBridgeApi()..toolsOverviewValue = _galaxy(),
      dark: true,
      // The camera settles into its framing, then comes closer.
      frames: 40,
      arrange: (t) async {
        final mouse = TestPointer(1, PointerDeviceKind.mouse);
        await t.sendEventToBinding(mouse.hover(const Offset(624, 400)));
        for (var i = 0; i < 3; i++) {
          await t.sendEventToBinding(mouse.scroll(const Offset(0, -60)));
        }
        // A slow, vertical drag only raises the view (no spin).
        await t.timedDragFrom(
          const Offset(624, 600),
          const Offset(0, 40),
          const Duration(seconds: 1),
        );
      },
      child: const GalaxyScreen(),
    );
    final phoneApi = await _phoneApi();
    final phone = await _shot(
      t,
      platform: TargetPlatform.iOS,
      size: const Size(393, 852),
      safeArea: const EdgeInsets.only(top: 54, bottom: 34),
      api: phoneApi,
      child: AppSessionScreen(
        serviceKey: _codex,
        threadId: _shareThread,
        home: true,
        services: phoneApi.services,
      ),
    );
    final services = await _shot(
      t,
      platform: TargetPlatform.macOS,
      size: const Size(440, 75),
      child: _services(),
    );
    final png = await t.runAsync(() async {
      final codec = await ui.instantiateImageCodec(
        img.encodePng(await renderMark((92 * _outputScale).round())),
      );
      final mark = (await codec.getNextFrame()).image;
      final poster = await _compose(
        galaxy: galaxy,
        sessions: sessions,
        phone: phone,
        services: services,
        mark: mark,
      );
      final data = await poster.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    for (final path in [
      '../../assets/logo/poster.png',
      'assets/logo/poster.png',
    ]) {
      // Synchronous: real I/O never completes inside the fake-async zone.
      File(path).writeAsBytesSync(png!);
    }
  }, skip: skip);
}
