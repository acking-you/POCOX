// A new native OpenCode conversation without a project folder (a fresh host
// with no saved project folders): OpenCode creates a session only in a
// folder, so a send first asks for one. Nothing is created, dispatched or
// shown as sent before that; cancelling keeps the draft; choosing a folder
// sends the message there once. A session that could not be created leaves
// the message in the composer, recoverable without duplicates.

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart'
    as fsel;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/tools/builtin_tags.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/opencode_chat.dart';
import 'support/screen_harness.dart';

const _svc = openCodeService;

Future<FakeBridgeApi> _open(WidgetTester t, {String? cwd}) => mountChat(
  t,
  FakeBridgeApi()..acpCapabilities[_svc] = negotiatedOpenCodeCapabilities(),
  cwd: cwd,
);

Future<void> _send(WidgetTester t) async {
  await t.tap(find.byKey(const Key('send-btn')));
  await t.pumpAndSettle();
}

/// No sent copy of [text] in the transcript (the composer may hold it).
Finder _bubble(String text) => find.descendant(
  of: find.byKey(const Key('chat-conversation-layer')),
  matching: find.text(text),
);

/// In the open folder picker (no project folders configured): type [path]
/// and use it.
Future<void> _useTypedFolder(WidgetTester t, String path) async {
  expect(find.byKey(const Key('folder-picker-no-roots')), findsOneWidget);
  await t.ensureVisible(find.byKey(const Key('folder-type-start')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('folder-type-start')));
  await t.pumpAndSettle();
  await t.enterText(find.byKey(const Key('folder-path-field')), path);
  await t.testTextInput.receiveAction(TextInputAction.go);
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('folder-use-btn')));
  await t.pumpAndSettle();
}

/// Close the open folder picker without choosing.
Future<void> _cancelPicker(WidgetTester t) async {
  Navigator.of(
    t.element(find.byKey(const Key('folder-picker-no-roots'))),
  ).pop();
  await t.pumpAndSettle();
}

/// Composer attachment chips (not their remove buttons).
Finder _chips() => find.byWidgetPredicate((w) {
  final key = w.key;
  return key is ValueKey<String> &&
      key.value.startsWith('attachment-') &&
      !key.value.startsWith('attachment-remove-');
});

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('without a folder the welcome asks for one', (t) async {
    await _open(t);
    expect(
      find.text('Choose a folder for OpenCode to work in.'),
      findsOneWidget,
    );
    expect(find.text('Work outside a project'), findsNothing);
  });

  testWidgets('a send without a folder asks for one; cancelling sends and '
      'shows nothing and keeps the draft', (t) async {
    final api = await _open(t);
    await typeMessage(t, 'hi');
    await _send(t);
    expect(find.byKey(const Key('folder-picker-no-roots')), findsOneWidget);
    expect(api.threadStartCalls, isEmpty);
    expect(api.turnStartCount, 0);
    await _cancelPicker(t);
    expect(api.threadStartCalls, isEmpty);
    expect(api.turnStartCount, 0);
    expect(composerText(t), 'hi');
    expect(_bubble('hi'), findsNothing, reason: 'no fake sent copy');
  });

  testWidgets('choosing the folder creates the session there and sends the '
      'message once, with the tools picked for it', (t) async {
    final api = FakeBridgeApi()
      ..acpCapabilities[_svc] = negotiatedOpenCodeCapabilities()
      ..toolsOverviewValue = const ToolsOverview(
        thisDevice: 'local',
        devices: [
          ToolsDevice(
            name: 'local',
            online: true,
            catalog: true,
            toolsEnabled: true,
            builtinTools: [
              ToolsBuiltinTool(
                id: 'share',
                title: 'Share a port',
                summary: '',
                gated: true,
              ),
            ],
          ),
        ],
      );
    await mountChat(t, api);
    await t.tap(find.byKey(const Key('attach-menu-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('builtin-tools-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('choice-share')));
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    await typeMessage(t, 'hi');
    await _send(t);
    await _useTypedFolder(t, '/srv/new');
    await frames(t);
    expect(api.threadStartCalls, [_svc]);
    expect(api.lastCwd, '/srv/new');
    expect(api.turnStartCount, 1);
    final sent = splitBuiltinTools(api.lastTurnText!);
    expect(sent.text, 'hi');
    expect(sent.ids, ['share']);
    expect(api.toolsGrants.single.$3, ['share']);
    expect(composerText(t), '');
    expect(_bubble('hi'), findsOneWidget);
  });

  testWidgets('a session that cannot be created leaves the message in the '
      'composer; Retry sends it once', (t) async {
    final api = await _open(t, cwd: '/work/alpha');
    api.threadStartError = StateError('opencode refused the session');
    await typeMessage(t, 'hi');
    await _send(t);
    await frames(t);
    expect(api.threadStartCalls, [_svc]);
    expect(api.turnStartCount, 0);
    expect(find.textContaining('opencode refused the session'), findsWidgets);
    expect(composerText(t), 'hi', reason: 'the message is back, unsent');
    expect(_bubble('hi'), findsNothing, reason: 'no fake sent copy');
    expect(find.byKey(const Key('conv-tile-thread-0')), findsNothing);
    // Nothing holds the composer: Retry sends what it holds, once.
    await t.tap(find.widgetWithText(TextButton, 'Retry'));
    await frames(t);
    expect(api.threadStartCalls, [_svc, _svc]);
    expect(api.turnStartCount, 1);
    expect(api.lastTurnText, 'hi');
    expect(composerText(t), '');
  });

  testWidgets('after a failed creation the message can be edited and sent '
      'once', (t) async {
    final api = await _open(t, cwd: '/work/alpha');
    api.threadStartError = StateError('opencode refused the session');
    await typeMessage(t, 'hi');
    await _send(t);
    await frames(t);
    await typeMessage(t, 'hi again');
    await _send(t);
    await frames(t);
    expect(api.turnStartCount, 1);
    expect(api.lastTurnText, 'hi again');
    expect(api.turnStartCalls, hasLength(1), reason: 'no duplicate');
  });

  testWidgets('desktop Enter without a folder asks for one and sends '
      'nothing', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = await _open(t);
      await typeMessage(t, 'hi');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('folder-picker-no-roots')), findsOneWidget);
      expect(api.threadStartCalls, isEmpty);
      expect(api.turnStartCount, 0);
      await _cancelPicker(t);
      expect(composerText(t), 'hi');
      expect(_bubble('hi'), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('cancelling the folder keeps the attachments with the text', (
    t,
  ) async {
    final previous = fsel.FileSelectorPlatform.instance;
    fsel.FileSelectorPlatform.instance = FakeFileSelector()
      ..files = [
        MemXFile(Uint8List.fromList([1, 2, 3]), 'notes.md'),
      ];
    addTearDown(() => fsel.FileSelectorPlatform.instance = previous);
    final api = await _open(t);
    await t.tap(find.byKey(const Key('attach-menu-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('attach-file-btn')));
    await frames(t);
    expect(_chips(), findsOneWidget);
    await typeMessage(t, 'hi');
    await _send(t);
    await _cancelPicker(t);
    expect(api.threadStartCalls, isEmpty);
    expect(api.turnStartCount, 0);
    expect(composerText(t), 'hi');
    expect(_chips(), findsOneWidget, reason: 'the attachment stays');
  });

  testWidgets('a folder whose project already holds an unsent draft keeps '
      'both, unsent', (t) async {
    final api = await _open(t);
    // An unsent draft in /srv/new...
    await t.tap(find.byKey(const Key('agent-welcome-choose-folder')));
    await t.pumpAndSettle();
    await _useTypedFolder(t, '/srv/new');
    await typeMessage(t, 'kept');
    // ...then back to no project, and a send there.
    await t.tap(find.byKey(const Key('project-switcher-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('project-menu-none')));
    await t.pumpAndSettle();
    expect(composerText(t), '');
    await typeMessage(t, 'hi');
    await _send(t);
    await _useTypedFolder(t, '/srv/new');
    await frames(t);
    expect(api.threadStartCalls, isEmpty, reason: 'nothing sent on its behalf');
    expect(api.turnStartCount, 0);
    expect(composerText(t), 'hi\n\nkept');
    expect(_bubble('hi'), findsNothing);
    // The user's own send sends the combined draft once.
    await _send(t);
    await frames(t);
    expect(api.turnStartCount, 1);
    expect(api.lastTurnText, 'hi\n\nkept');
  });

  testWidgets('New conversation after a refused creation starts clean and '
      'keeps the returned draft', (t) async {
    final api = await _open(t, cwd: '/work/alpha');
    api.threadStartError = StateError('opencode refused the session');
    await typeMessage(t, 'hi');
    await _send(t);
    await frames(t);
    expect(find.textContaining('opencode refused the session'), findsWidgets);
    final newChat = find.byKey(const Key('new-conversation-btn'));
    await t.ensureVisible(newChat.first);
    await t.tap(newChat.first);
    await frames(t);
    expect(find.textContaining('opencode refused the session'), findsNothing);
    expect(composerText(t), 'hi');
    expect(_bubble('hi'), findsNothing);
    await _send(t);
    await frames(t);
    expect(api.threadStartCalls, [_svc, _svc]);
    expect(api.turnStartCount, 1);
    expect(api.lastTurnText, 'hi');
  });
}
