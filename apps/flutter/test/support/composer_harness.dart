/// The conversation screen mounted around its composer, shared by the
/// composer tests.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/screens/app_session_screen.dart';

import '../fake_bridge_api.dart';
import 'screen_harness.dart';

/// The service the composer tests talk to.
const composerService = 'pcx:host:app:default';

/// The composer's text field.
final composerInput = find.byKey(const Key('composer-input'));

/// Mount the conversation [thread] on [service] and settle (or, without
/// [settle], pump a few frames).
Future<void> mountComposer(
  WidgetTester t,
  FakeBridgeApi api, {
  String service = composerService,
  String? thread = 'a',
  String? cwd,
  bool settle = true,
}) async {
  await api.appConnect(service, 28080);
  await t.pumpWidget(
    host(
      AppSessionScreen(
        key: ValueKey(service),
        serviceKey: service,
        threadId: thread,
        cwd: cwd,
        home: true,
      ),
      api,
      locale: const Locale('en'),
    ),
  );
  if (settle) {
    await t.pumpAndSettle();
  } else {
    await composerFrames(t);
  }
}

/// A few frames, for screens whose animations never settle.
Future<void> composerFrames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// The composer's controller.
TextEditingController composerController(WidgetTester t) =>
    t.widget<TextField>(composerInput).controller!;
