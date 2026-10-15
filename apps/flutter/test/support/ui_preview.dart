// Shared preview support for layout tests: real bundled fonts and optional
// PNG export. Set PCX_UI_PREVIEW_DIR to write each captured layout as a PNG.
//
// Fonts come from the test asset bundle (Figtree, Geist Mono, Material
// Icons) and, for Chinese, the desktop-only Noto Sans SC read from the
// source tree. Nothing is downloaded and the mobile asset bundle is
// unchanged.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wraps what a preview captures; place it around the navigator so dialogs
/// and sheets are part of the image.
const previewKey = Key('ui-preview');

/// Where previews are written, or null when they are not requested.
String? get previewDir => Platform.environment['PCX_UI_PREVIEW_DIR'];

/// Load the app's real fonts. With [always] false (the default) this only
/// happens when previews are requested, so ordinary runs keep the test
/// font; pass true where a test measures real text.
Future<void> loadPreviewFonts({bool always = false}) async {
  if (!always && previewDir == null) return;
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  // Figtree also stands in for the Apple system face, which the headless
  // engine lacks, so iOS-platform previews measure real Latin text.
  for (final family in ['Figtree', 'CupertinoSystemText']) {
    final prose = FontLoader(family);
    for (final weight in ['Light', 'Regular', 'Medium', 'SemiBold', 'Bold']) {
      prose.addFont(rootBundle.load('assets/fonts/Figtree-$weight.ttf'));
    }
    await prose.load();
  }
  final mono = FontLoader('GeistMono');
  for (final weight in ['Regular', 'Medium', 'SemiBold']) {
    mono.addFont(rootBundle.load('assets/fonts/GeistMono-$weight.ttf'));
  }
  await mono.load();
  // The headless engine has no OS CJK fonts. This preview-only fallback
  // does not add the desktop font to the mobile asset bundle.
  await (FontLoader('Noto Sans SC')..addFont(
        File(
          'assets/fonts/NotoSansSC-VariableFont_wght.ttf',
        ).readAsBytes().then(ByteData.sublistView),
      ))
      .load();
}

/// Write the [previewKey] boundary as `<name>.png` when previews are
/// requested.
Future<void> capturePreview(WidgetTester t, String name) async {
  final dir = previewDir;
  if (dir == null) return;
  final boundary = t.renderObject<RenderRepaintBoundary>(
    find.byKey(previewKey),
  );
  await t.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(dir).create(recursive: true);
    await File('$dir/$name.png').writeAsBytes(data!.buffer.asUint8List());
  });
}
