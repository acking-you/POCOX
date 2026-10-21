// The host's default project folder in a new conversation. An automatic
// default (not chosen by anyone) is only shown: a send without a chosen
// folder goes out with no cwd and the host creates and uses its default
// then, never earlier. A chosen default seeds the draft's folder. A late
// default answer never replaces a folder the user picked meanwhile.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/opencode_chat.dart';

const _svc = openCodeService;
const _auto = '/Users/me/pocox';

FakeBridgeApi _api({ProjectSettings? settings}) {
  final api = FakeBridgeApi()
    ..acpCapabilities[_svc] = negotiatedOpenCodeCapabilities();
  if (settings != null) api.projectSettings[_svc] = settings;
  return api;
}

const _automatic = ProjectSettings(
  revision: '1',
  effectiveDefault: _auto,
  automatic: true,
);

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('with an automatic default a send goes straight out without '
      'a folder picker; the host chooses the folder', (t) async {
    final api = await mountChat(t, _api(settings: _automatic));
    expect(find.text('pocox (default)'), findsWidgets);
    expect(api.projectSettingsSaves, isEmpty, reason: 'nothing is created');
    await typeMessage(t, 'hi');
    await tapSend(t);
    expect(find.byKey(const Key('folder-picker-no-roots')), findsNothing);
    expect(api.threadStartCalls, [_svc]);
    expect(api.lastCwd, isNull, reason: 'the host ensures its default');
    expect(api.turnStartCount, 1);
    expect(composerText(t), '');
  });

  testWidgets('a chosen default seeds the conversation folder', (t) async {
    final api = await mountChat(
      t,
      _api(
        settings: const ProjectSettings(
          revision: '2',
          defaultProject: '/srv/app',
          effectiveDefault: '/srv/app',
          exists: true,
        ),
      ),
    );
    await typeMessage(t, 'hi');
    await tapSend(t);
    expect(api.lastCwd, '/srv/app');
    expect(api.turnStartCount, 1);
  });

  testWidgets('an older host without project settings still asks for a '
      'folder', (t) async {
    final api = await mountChat(t, _api());
    await typeMessage(t, 'hi');
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('folder-picker-no-roots')), findsOneWidget);
    expect(api.threadStartCalls, isEmpty);
  });

  testWidgets('an explicit folder wins over a late automatic default', (
    t,
  ) async {
    final gate = Completer<void>();
    final api = _api(settings: _automatic)..projectSettingsGate = gate;
    await mountChat(t, api, cwd: '/work/alpha');
    gate.complete();
    await frames(t);
    await typeMessage(t, 'hi');
    await tapSend(t);
    expect(api.lastCwd, '/work/alpha');
    expect(find.text('pocox (default)'), findsNothing);
  });

  testWidgets('a failed session creation keeps the message in the '
      'composer and sends nothing by itself', (t) async {
    final api = await mountChat(t, _api(settings: _automatic));
    api.threadStartError = StateError('cannot create the default folder');
    await typeMessage(t, 'hi');
    await tapSend(t);
    expect(api.threadStartCalls, [_svc]);
    expect(api.turnStartCount, 0);
    expect(composerText(t), 'hi');
    await frames(t);
    expect(api.threadStartCalls, [_svc], reason: 'no automatic resend');
  });

  Future<void> newConversation(WidgetTester t) async {
    final button = find.byKey(const Key('new-conversation-btn'));
    await t.ensureVisible(button.first);
    await t.tap(button.first);
    await frames(t);
  }

  testWidgets('a later new conversation reads the host default again: a '
      'default chosen meanwhile seeds its folder', (t) async {
    final api = _api(settings: _automatic)
      ..appThreads.add(
        const ThreadMeta(id: 't1', preview: 'old', cwd: '', updatedAt: 1),
      );
    await mountChat(t, api, threadId: 't1');
    await newConversation(t);
    expect(find.text('pocox (default)'), findsWidgets);
    // Back to the existing conversation; another device then chooses a
    // default while this screen stays open.
    await t.tap(find.byKey(const Key('conv-tile-t1')));
    await frames(t);
    api.projectSettings[_svc] = const ProjectSettings(
      revision: '2',
      defaultProject: '/srv/next',
      effectiveDefault: '/srv/next',
      exists: true,
    );
    await newConversation(t);
    expect(find.text('pocox (default)'), findsNothing);
    await typeMessage(t, 'hi');
    await tapSend(t);
    expect(find.byKey(const Key('folder-picker-no-roots')), findsNothing);
    expect(api.lastCwd, '/srv/next');
  });

  testWidgets('after an automatic first send the conversation takes the '
      'folder the host lists for it', (t) async {
    final api = _api(settings: _automatic)..threadStartDefaultCwd = _auto;
    await mountChat(t, api);
    await typeMessage(t, 'hi');
    await tapSend(t);
    expect(api.lastCwd, isNull);
    await frames(t);
    // A new conversation from here stays in that project: the folder was
    // adopted from the host's answer.
    await newConversation(t);
    await typeMessage(t, 'next');
    await tapSend(t);
    expect(api.lastCwd, _auto);
  });

  testWidgets('a late list for the automatic conversation does not move the '
      'conversation shown since', (t) async {
    final api = _api(settings: _automatic)..threadStartDefaultCwd = _auto;
    await mountChat(t, api);
    final gate = Completer<void>();
    api.threadListGate = gate.future;
    await typeMessage(t, 'hi');
    await tapSend(t);
    // Leave for a new conversation before the host's list answers.
    await newConversation(t);
    api.threadListGate = null;
    gate.complete();
    await frames(t);
    expect(find.text('pocox (default)'), findsWidgets);
    await typeMessage(t, 'next');
    await tapSend(t);
    expect(api.lastCwd, isNull, reason: 'still the automatic default');
  });
}
