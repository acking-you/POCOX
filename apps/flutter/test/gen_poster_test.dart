// Derives the README poster from the app itself: the chat screen rendered on
// a desktop and on a phone with the bundled fonts, the light theme and fixture
// data (no real session), set beside the mark and the POCOX wordmark, whose
// letters are spelled out of "POcket COdeX".
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
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:image/image.dart' as img;

import 'fake_bridge_api.dart';
import 'gen_icon_test.dart' show renderMark;
import 'support/ui_preview.dart';

const _codex = 'pcx:studio:app:default';
const _cwd = '/Users/me/work/pocox';

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

LocalSession _running(String id, String name) => LocalSession(
  threadId: id,
  cwd: _cwd,
  preview: name,
  name: name,
  status: 'active',
  updatedAt: _ago(Duration.zero),
  turnState: 'incomplete',
  heldOpen: true,
  safety: 'ownedRunning',
  allowsResume: true,
  requiresTakeover: false,
);

Future<FakeBridgeApi> _api(ThreadHistory history) async {
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
        ..appThreads.addAll([
          _thread(
            't1',
            'Follow the app-server for session state',
            const Duration(minutes: 3),
          ),
          _thread(
            't2',
            'Fix the flaky port test in core',
            const Duration(minutes: 1),
          ),
          _thread(
            't3',
            'Sweep phone layouts at 320 px',
            const Duration(hours: 2),
          ),
          _thread(
            't4',
            'Draft the 0.3.1 release notes',
            const Duration(hours: 5),
            cwd: '/Users/me/work/pocox-site',
          ),
          _thread(
            't5',
            'Review relay recovery logs',
            const Duration(days: 1),
            cwd: '/Users/me/work/relay',
          ),
          _thread(
            't6',
            'Explain the pb-mapper handshake',
            const Duration(days: 2),
            cwd: '/Users/me/work/relay',
          ),
        ])
        ..localSessions = [_running('t2', 'Fix the flaky port test in core')]
        ..readResult = history;
  await api.appConnect(_codex, 1);
  return api;
}

const _desktopHistory = ThreadHistory(
  running: false,
  branch: 'codex-sync',
  cwd: _cwd,
  model: 'gpt-5.5',
  reasoningEffort: 'high',
  items: [
    ThreadItem(
      id: 'u0',
      itemType: 'userMessage',
      title: '',
      text: 'Why does Local sessions miss my older conversations?',
      turnId: 'turn0',
    ),
    ThreadItem(
      id: 'a0',
      itemType: 'agentMessage',
      title: '',
      text:
          'Codex compresses rollouts idle for a week to `.jsonl.zst`, and '
          'the scanner only read `.jsonl`: here that hid 770 of 1059 '
          'sessions. Every reader now accepts both.',
      turnId: 'turn0',
      turnDurationMs: 48000,
    ),
    ThreadItem(
      id: 'u1',
      itemType: 'userMessage',
      title: '',
      text:
          'Take running state from the app-server itself, and keep the '
          'rollout probes only for writers it cannot see.',
      turnId: 'turn1',
    ),
    ThreadItem(
      id: 'c1',
      itemType: 'commandExecution',
      title: 'rg -n "running_only" crates',
      text: 'crates/pocket-codex-host-svc/src/codex_routes.rs:22',
      turnId: 'turn1',
      turnDurationMs: 134000,
    ),
    ThreadItem(
      id: 'c2',
      itemType: 'commandExecution',
      title: 'cargo test --workspace --locked',
      text: 'test result: ok. 847 passed; 0 failed',
      turnId: 'turn1',
      turnDurationMs: 134000,
    ),
    ThreadItem(
      id: 'a1',
      itemType: 'agentMessage',
      title: '',
      text:
          'Done. Session state now comes from the app-server:\n\n'
          '- `thread/list` names every session, compressed ones included\n'
          '- `Thread.status` marks what this host runs, so opening one joins '
          'it instead of taking it over\n'
          '- `lsof` stays only for writers in other processes\n\n'
          'All 847 Rust tests pass.',
      turnId: 'turn1',
      turnDurationMs: 134000,
    ),
  ],
);

const _phoneHistory = ThreadHistory(
  running: true,
  activeTurnId: 'turn2',
  branch: 'main',
  cwd: _cwd,
  model: 'gpt-5.5',
  items: [
    ThreadItem(
      id: 'u2',
      itemType: 'userMessage',
      title: '',
      text: 'Run the core tests again and fix the flaky one.',
      turnId: 'turn2',
    ),
    ThreadItem(
      id: 'a2',
      itemType: 'agentMessage',
      title: '',
      text:
          'The port test frees its port before checking it, so a parallel '
          'test can take it. I will rerun it alone first.',
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

/// [screen] rendered on [platform] at [size] (logical pixels).
Future<ui.Image> _shot(
  WidgetTester t, {
  required TargetPlatform platform,
  required Size size,
  required FakeBridgeApi api,
  required Widget screen,
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
        overrides: [bridgeApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('en'),
          theme: lightTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              RepaintBoundary(key: previewKey, child: child!),
          home: screen,
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

void _image(Canvas canvas, ui.Image image, RRect into) {
  canvas.save();
  canvas.clipRRect(into);
  canvas.drawImageRect(
    image,
    Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
    into.outerRect,
    Paint()..filterQuality = FilterQuality.high,
  );
  canvas.restore();
}

/// The desktop window: the captured screen with macOS window controls in its
/// title strip and a hairline edge.
void _window(Canvas canvas, ui.Image screen, Rect at) {
  final shape = RRect.fromRectAndRadius(at, const Radius.circular(14));
  _shadow(canvas, shape, blur: 48, y: 28);
  _image(canvas, screen, shape);
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
  _image(canvas, screen, inner);
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

Future<ui.Image> _compose(ui.Image desktop, ui.Image phone, ui.Image mark) {
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
  canvas.drawImageRect(
    mark,
    Offset.zero & Size(mark.width.toDouble(), mark.height.toDouble()),
    const Rect.fromLTWH(left - 4, 180, 100, 100),
    Paint()..filterQuality = FilterQuality.high,
  );
  canvas.drawParagraph(
    _text([('POCOX', _ink)], size: 120, weight: FontWeight.w700, spacing: -2.5),
    const Offset(left - 6, 292),
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
    const Offset(left, 440),
  );
  canvas.drawParagraph(
    _text(
      [('Your Codex,\nin your pocket.', _ink)],
      size: 46,
      weight: FontWeight.w600,
      height: 1.14,
      spacing: -0.6,
      width: 460,
    ),
    const Offset(left, 534),
  );
  canvas.drawParagraph(
    _text(
      [
        (
          'Host Codex on your computer. Follow and steer every turn, '
              'answer approvals and read history from a phone, a tablet or '
              'another desktop.',
          _muted,
        ),
      ],
      size: 20,
      height: 1.5,
      width: 420,
    ),
    const Offset(left, 666),
  );
  var x = left;
  for (final label in ['iOS · Android', 'macOS · Windows · Linux']) {
    final text = _text([(label, _ink)], size: 16, weight: FontWeight.w500);
    final pill = RRect.fromRectAndRadius(
      Rect.fromLTWH(x, 828, text.maxIntrinsicWidth + 30, 38),
      const Radius.circular(19),
    );
    canvas.drawRRect(pill, Paint()..color = Colors.white);
    canvas.drawRRect(
      pill,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = _hairline,
    );
    canvas.drawParagraph(text, Offset(x + 15, 828 + (38 - text.height) / 2));
    x = pill.right + 10;
  }

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
    final desktop = await _shot(
      t,
      platform: TargetPlatform.macOS,
      size: const Size(1040, 740),
      api: await _api(_desktopHistory),
      screen: const AppSessionScreen(
        serviceKey: _codex,
        threadId: 't1',
        home: true,
      ),
    );
    final phoneApi = await _api(_phoneHistory);
    final phone = await _shot(
      t,
      platform: TargetPlatform.iOS,
      size: const Size(393, 852),
      safeArea: const EdgeInsets.only(top: 54, bottom: 34),
      api: phoneApi,
      screen: const AppSessionScreen(
        serviceKey: _codex,
        threadId: 't2',
        home: true,
      ),
      then: () async {
        phoneApi.pushEvent(
          _codex,
          const AppEvent(
            kind: 'execCommandApproval',
            threadId: 't2',
            requestId: '7',
            raw:
                '{"command":"cargo test -p pocket-codex-core '
                'tcp_port_open","cwd":"$_cwd"}',
          ),
        );
        await _frames(t);
      },
    );
    final png = await t.runAsync(() async {
      final codec = await ui.instantiateImageCodec(
        img.encodePng(await renderMark(224)),
      );
      final mark = (await codec.getNextFrame()).image;
      final poster = await _compose(desktop, phone, mark);
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
