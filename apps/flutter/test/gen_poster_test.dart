// Derives the README poster from the app itself: a desktop on Codex with the
// switcher over every device's agents open, and a phone on Claude answering a
// permission request, rendered with the bundled fonts, the light theme and
// fixture data (no real session), beside the mark, the POCOX wordmark (spelled
// out of "POcket COdeX") and the services within reach.
//
// Opt-in like gen_icon_test (PNG output differs across platforms):
//   REGEN_ICONS=1 fvm flutter test test/gen_poster_test.dart
//
// Outputs (both copies kept identical):
//   assets/logo/poster.png, apps/flutter/assets/logo/poster.png
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/app_session/agent_permission_card.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/agent_icon.dart';

import 'fake_bridge_api.dart';
import 'gen_icon_test.dart' show renderMark;
import 'support/acp_capabilities.dart';
import 'support/ui_preview.dart';

const _codex = 'pcx:studio:app:default';
const _claude = 'pcx:studio:acp:claude';
const _openCode = 'pcx:devbox:opencode:opencode';
const _windows = 'pcx:gaming-pc:app:default';
const _cwd = '/Users/me/work/atlas';

/// The poster's size, in pixels.
const _poster = Size(1536, 1024);

/// Screens are captured at twice their logical size, so they stay sharp once
/// scaled into the poster.
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

ThreadMeta _thread(String id, String name, Duration ago, {String? cwd}) =>
    ThreadMeta(
      id: id,
      preview: name,
      name: name,
      cwd: cwd ?? _cwd,
      updatedAt: _ago(ago),
    );

/// One account's devices: a Mac hosting Codex and Claude, a Linux box hosting
/// OpenCode and a Windows PC hosting Codex.
Future<FakeBridgeApi> _api(String connect, ThreadHistory history) async {
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
            ServiceEntry(
              device: 'studio',
              kind: 'acp',
              name: 'claude',
              key: _claude,
            ),
            ServiceEntry(
              device: 'devbox',
              kind: 'opencode',
              name: 'opencode',
              key: _openCode,
            ),
            ServiceEntry(
              device: 'gaming-pc',
              kind: 'app',
              name: 'default',
              key: _windows,
            ),
          ],
        )
        ..acpCapabilities[_claude] = negotiatedAcpCapabilities(
          providerName: 'Claude',
          profileId: 'claude',
          steer: true,
        )
        ..acpCapabilities[_openCode] = negotiatedOpenCodeCapabilities()
        // Signed in to Codex on this Mac.
        ..codexStatus = const CodexSetupStatus(
          codexHome: '/Users/me/.codex',
          hasConfig: true,
          hasAuth: true,
          hasCustomProvider: false,
          authMode: 'chatgpt',
          needsSetup: false,
          promptVariant: 'default',
        )
        // This Mac's own hosts, so the switcher knows their agents.
        ..serveHosts.addAll(const [
          AppServeStatus(
            name: 'default',
            device: 'studio',
            alive: true,
            appServiceKey: _codex,
            appRegistered: true,
          ),
          AppServeStatus(
            name: 'claude',
            device: 'studio',
            alive: true,
            appServiceKey: _claude,
            appRegistered: true,
            provider: 'acp',
            providerName: 'Claude',
            profileId: 'claude',
          ),
        ])
        ..modelLists[_codex] = const [
          ModelInfo(
            id: 'gpt-6-astra',
            displayName: 'GPT-6-Astra',
            description: '',
            supportedReasoningEfforts: ['low', 'medium', 'high', 'xhigh'],
            defaultReasoningEffort: 'medium',
          ),
        ]
        ..sessionSettings['$_claude|ses-1'] = const SessionSettings(
          configOptions: [
            SessionConfigOption(
              id: 'model',
              name: 'Model',
              category: 'model',
              currentValue: 'opus',
              values: [
                SessionConfigValue(value: 'opus', name: 'Opus 5.5'),
                SessionConfigValue(value: 'sonnet', name: 'Sonnet 5.5'),
              ],
            ),
          ],
        )
        ..appThreads.addAll([
          _thread(
            't1',
            'Speed up the Windows build',
            const Duration(minutes: 4),
          ),
          _thread(
            't2',
            'Profile the import pipeline',
            const Duration(minutes: 1),
          ),
          _thread(
            't3',
            'Tidy the settings page on phones',
            const Duration(hours: 3),
          ),
          _thread(
            't4',
            'Draft the release notes',
            const Duration(hours: 6),
            cwd: '/Users/me/work/atlas-site',
          ),
          _thread(
            'ses-1',
            'Why is the nightly build red?',
            const Duration(seconds: 30),
          ),
        ])
        ..localSessions = [
          LocalSession(
            threadId: 't2',
            cwd: _cwd,
            preview: 'Profile the import pipeline',
            name: 'Profile the import pipeline',
            status: 'active',
            updatedAt: _ago(Duration.zero),
            turnState: 'incomplete',
            heldOpen: true,
            safety: 'ownedRunning',
            allowsResume: true,
            requiresTakeover: false,
          ),
        ]
        ..readResult = history;
  await api.appConnect(connect, 1);
  return api;
}

const _desktopHistory = ThreadHistory(
  running: false,
  branch: 'ci-cache',
  cwd: _cwd,
  model: 'gpt-6-astra',
  reasoningEffort: 'high',
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

const _phoneHistory = ThreadHistory(
  running: true,
  activeTurnId: 'turn2',
  cwd: _cwd,
  items: [
    ThreadItem(
      id: 'u2',
      itemType: 'userMessage',
      title: '',
      text: 'Find out why the nightly build is red, and fix it.',
      turnId: 'turn2',
    ),
    ThreadItem(
      id: 'a2',
      itemType: 'agentMessage',
      title: '',
      text:
          'The arm64 job links with the host `ar`. Pointing it at the cross '
          "toolchain's archiver fixes the link; I'd like to edit the workflow.",
      turnId: 'turn2',
    ),
  ],
);

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
  Future<void> Function()? then,
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
          theme: lightTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, navigator) =>
              RepaintBoundary(key: previewKey, child: navigator!),
          home: child,
        ),
      ),
    );
    await _frames(t);
    await then?.call();
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
  required ui.Image desktop,
  required ui.Image phone,
  required ui.Image services,
  required ui.Image mark,
}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
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
  _image(canvas, mark, const Rect.fromLTWH(left - 4, 150, 100, 100));
  canvas.drawParagraph(
    _text([('POCOX', _ink)], size: 120, weight: FontWeight.w700, spacing: -2.5),
    const Offset(left - 6, 262),
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
      size: 40,
      weight: FontWeight.w600,
      spacing: 1,
    ),
    const Offset(left, 410),
  );
  canvas.drawParagraph(
    _text(
      [('Every device,\nin your pocket.', _ink)],
      size: 46,
      weight: FontWeight.w600,
      height: 1.14,
      spacing: -0.6,
      width: 460,
    ),
    const Offset(left, 504),
  );
  canvas.drawParagraph(
    _text(
      [
        (
          'Your computers, and the agents, services and subscriptions on '
              'them, within reach from a phone, a tablet or any other '
              'machine.',
          _muted,
        ),
      ],
      size: 20,
      height: 1.5,
      width: 420,
    ),
    const Offset(left, 636),
  );
  final chips = Size(
    services.width / _captureScale,
    services.height / _captureScale,
  );
  _image(canvas, services, const Offset(left, 772) & chips);
  canvas.drawParagraph(
    _text(
      [('iOS · Android · macOS · Windows · Linux', _faint)],
      size: 16,
      weight: FontWeight.w500,
      spacing: 0.2,
    ),
    Offset(left + 2, 772 + chips.height + 18),
  );

  _window(canvas, desktop, const Rect.fromLTWH(696, 104, 776, 552));
  _phone(canvas, phone, const Rect.fromLTWH(584, 384, 266, 568));
  return recorder.endRecording().toImage(
    _poster.width.toInt(),
    _poster.height.toInt(),
  );
}

void main() {
  // PNG output differs across platforms: regenerate only on request.
  final skip = Platform.environment['REGEN_ICONS'] != '1';

  setUpAll(() => loadPreviewFonts(always: true));
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('derive the README poster from the app', (t) async {
    final desktopApi = await _api(_codex, _desktopHistory);
    final desktop = await _shot(
      t,
      platform: TargetPlatform.macOS,
      size: const Size(1040, 740),
      api: desktopApi,
      child: AppSessionScreen(
        serviceKey: _codex,
        threadId: 't1',
        home: true,
        services: desktopApi.services,
      ),
      then: () async {
        await t.tap(find.byKey(const Key('sidebar-service-switcher')));
        await _frames(t);
      },
    );
    final phoneApi = await _api(_claude, _phoneHistory);
    final phone = await _shot(
      t,
      platform: TargetPlatform.iOS,
      size: const Size(393, 852),
      safeArea: const EdgeInsets.only(top: 54, bottom: 34),
      api: phoneApi,
      child: AppSessionScreen(
        serviceKey: _claude,
        threadId: 'ses-1',
        home: true,
        services: phoneApi.services,
      ),
      then: () async {
        phoneApi.pushEvent(
          _claude,
          const AppEvent(
            kind: agentPermissionKind,
            threadId: 'ses-1',
            requestId: 'p1',
            title: 'Edit .github/workflows/nightly.yml',
            raw:
                '{"threadId":"ses-1","toolCall":{"title":"Edit '
                '.github/workflows/nightly.yml","locations":[{"path":'
                '"$_cwd/.github/workflows/nightly.yml"}]},"options":['
                '{"optionId":"allow","name":"Allow once","kind":"allow_once"},'
                '{"optionId":"always","name":"Always allow edits",'
                '"kind":"allow_always"},'
                '{"optionId":"reject","name":"Reject","kind":"reject_once"}]}',
          ),
        );
        await _frames(t);
      },
    );
    final services = await _shot(
      t,
      platform: TargetPlatform.macOS,
      size: const Size(500, 34),
      child: _services(),
    );
    final png = await t.runAsync(() async {
      final codec = await ui.instantiateImageCodec(
        img.encodePng(await renderMark(224)),
      );
      final mark = (await codec.getNextFrame()).image;
      final poster = await _compose(
        desktop: desktop,
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
