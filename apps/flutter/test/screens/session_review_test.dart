import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';

import '../fake_bridge_api.dart';
import '../support/screen_harness.dart';

const _service = 'pcx:lb7666:app:default';

/// The environment button is a desktop affordance.
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

String _diffOf(String path) =>
    'diff --git a/$path b/$path\n'
    '--- a/$path\n'
    '+++ b/$path\n'
    '@@ -1 +1 @@\n'
    '-old\n'
    '+new\n';

/// A wide conversation in `/proj` whose working tree is [diff].
Future<FakeBridgeApi> _mount(WidgetTester t, String diff) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(1600, 1000);
  addTearDown(t.view.reset);
  final api = FakeBridgeApi(
    config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
  );
  await api.appConnect(_service, 28080);
  api.readResult = const ThreadHistory(
    items: [
      ThreadItem(id: 'u1', itemType: 'userMessage', title: '', text: 'hi'),
    ],
    running: false,
    branch: 'main',
    cwd: '/proj',
  );
  api.gitDiffText = diff;
  await t.pumpWidget(
    host(const AppSessionScreen(serviceKey: _service, threadId: 't'), api),
  );
  await t.pumpAndSettle();
  return api;
}

Future<void> _tapEnv(WidgetTester t) async {
  await t.tap(find.byKey(const Key('env-panel-btn')));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('an older working-tree read answering last is dropped', (
    t,
  ) async {
    final api = await _mount(t, _diffOf('lib/start.dart'));
    // A read of the old tree hangs while a newer read answers first.
    final slow = Completer<void>();
    api
      ..gitDiffText = _diffOf('lib/old.dart')
      ..gitDiffGate = slow;
    await _tapEnv(t);
    await _tapEnv(t); // close
    api
      ..gitDiffText = _diffOf('lib/new.dart')
      ..gitDiffGate = null;
    await _tapEnv(t);
    expect(find.byKey(const Key('env-file-lib/new.dart')), findsOneWidget);
    slow.complete();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('env-file-lib/new.dart')), findsOneWidget);
    expect(find.byKey(const Key('env-file-lib/old.dart')), findsNothing);
  }, variant: _desktop);

  testWidgets('Review all again returns the review to the working tree', (
    t,
  ) async {
    await _mount(t, _diffOf('lib/x.dart'));
    Future<void> reviewAll() async {
      await _tapEnv(t);
      await t.tap(find.byKey(const Key('env-review-all')));
      await t.pumpAndSettle();
    }

    await reviewAll();
    expect(find.byKey(const Key('review-file-lib/x.dart')), findsOneWidget);
    await t.tap(find.byKey(const Key('review-source-session')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('review-file-lib/x.dart')), findsNothing);
    await reviewAll();
    expect(find.byKey(const Key('review-file-lib/x.dart')), findsOneWidget);
  }, variant: _desktop);
}
