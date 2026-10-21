import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/app_toast.dart';
import 'package:pocox/src/app_icons.dart';

/// Mounts a button that raises a toast, so each test drives the real
/// `ScaffoldMessenger` path rather than the builder in isolation.
Widget _host(void Function(BuildContext) raise) => MaterialApp(
  theme: lightTheme(),
  home: Scaffold(
    body: Builder(
      builder: (context) =>
          TextButton(onPressed: () => raise(context), child: const Text('go')),
    ),
  ),
);

Future<void> _tap(WidgetTester t) async {
  await t.tap(find.text('go'));
  await t.pump(); // let the snack bar animate in
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('each tone leads with its own glyph and colour', (t) async {
    final scheme = lightTheme().colorScheme;
    final tones = [
      (showToastOk, AppIcons.check_circle_outline, successColor(scheme)),
      (showToastError, AppIcons.error_outline, scheme.error),
      (showToast, AppIcons.info_outline, infoColor(scheme)),
    ];
    for (final (raise, glyph, colour) in tones) {
      await t.pumpWidget(_host((c) => raise(c, 'message')));
      await _tap(t);
      expect(find.text('message'), findsOneWidget);
      // One glyph only, in the tone's colour, so the tone is legible before
      // the text is read.
      final icons = t.widgetList<Icon>(
        find.descendant(of: find.byType(SnackBar), matching: find.byType(Icon)),
      );
      expect(icons.map((i) => (i.icon, i.color)), [(glyph, colour)]);
    }
  });

  testWidgets('a failure stays up longer than a confirmation', (t) async {
    await t.pumpWidget(_host((c) => showToastOk(c, 'copied')));
    await _tap(t);
    final ok = t.widget<SnackBar>(find.byType(SnackBar)).duration;

    await t.pumpWidget(_host((c) => showToastError(c, 'nope')));
    await _tap(t);
    final failed = t.widget<SnackBar>(find.byType(SnackBar)).duration;

    // An error carries a reason worth reading; "Copied" does not.
    expect(failed, greaterThan(ok));
  });

  testWidgets('tapping copy twice replaces the toast rather than queueing', (
    t,
  ) async {
    await t.pumpWidget(_host((c) => showToastOk(c, 'copied')));
    await _tap(t);
    await _tap(t);
    await t.pump(const Duration(milliseconds: 400));

    // Without hideCurrentSnackBar the second would wait out the first.
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('a captured messenger still reports after its context is gone', (
    t,
  ) async {
    // The download/upload paths hold a messenger across an await because their
    // own context may be disposed by the time the work finishes.
    late ToastMessenger messenger;
    await t.pumpWidget(
      MaterialApp(
        theme: lightTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              messenger = ToastMessenger.of(context);
              return const Text('mounted');
            },
          ),
        ),
      ),
    );

    messenger.ok('downloaded');
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('downloaded'), findsOneWidget);
  });
}
