// ACP sessions in the shared session screen: native-only calls are never
// made, native microphone features are absent, agent permissions are
// answered with the agent's own option ids, and per-session agent options
// replace the model catalog.

import 'dart:async';
import 'dart:convert';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart'
    as fsel;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/screens/app_session/activity_cards.dart';
import 'package:pocket_codex/src/screens/app_session/agent_permission_card.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/voice/dictation_widgets.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/screen_harness.dart';

part 'acp_session/attachments.dart';
part 'acp_session/omissions.dart';

const acp = 'pcx:dev:acp:agent';
const codex = 'pcx:dev:app:default';

final negotiated = negotiatedAcpCapabilities(
  providerName: 'Beta agent',
  generation: 3,
);

/// [negotiated], for an agent that advertised image prompts.
final negotiatedWithImages = negotiatedAcpCapabilities(
  providerName: 'Beta agent',
  generation: 3,
  imageInput: true,
);

/// A file picker that answers only when the test completes [selection].
class PausedFileSelector extends FakeFileSelector {
  final selection = Completer<List<fsel.XFile>>();

  @override
  Future<List<fsel.XFile>> openFiles({
    List<fsel.XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) => selection.future;
}

/// A picked file whose contents are read only when the test completes
/// [read].
class SlowMemXFile extends MemXFile {
  SlowMemXFile(super.bytes, super.name);
  final read = Completer<void>();

  @override
  Future<Uint8List> readAsBytes() async {
    await read.future;
    return super.readAsBytes();
  }
}

/// The agent host behind the connection was lost.
const hostLost = AppEvent(kind: 'acp/host/state', raw: '{"connected":false}');

class AcpApi extends FakeBridgeApi {
  int modelListCalls = 0;
  int rateLimitCalls = 0;

  @override
  Future<List<ModelInfo>> appModelList(String serviceKey) async {
    modelListCalls++;
    return const [];
  }

  @override
  Future<String> appRateLimits(String serviceKey) {
    rateLimitCalls++;
    return super.appRateLimits(serviceKey);
  }
}

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> open(
  WidgetTester t,
  FakeBridgeApi api,
  String key, {
  String? thread,
}) async {
  await api.appConnect(key, 28080);
  await t.pumpWidget(
    host(AppSessionScreen(serviceKey: key, threadId: thread), api),
  );
  await frames(t);
}

/// Composer attachment chips (not their remove buttons).
Finder attachmentChips() => find.byWidgetPredicate((w) {
  final key = w.key;
  return key is ValueKey<String> &&
      key.value.startsWith('attachment-') &&
      !key.value.startsWith('attachment-remove-');
});

/// Run [body] as a desktop app (registers the paste key handler and the drop
/// target). Reset inside the body so the debug-variable check passes.
Future<void> onDesktop(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// Fake clipboard contents for Ctrl/Cmd+V, restored afterwards.
void fakeClipboard({Uint8List? image, List<String> files = const []}) {
  final previousImage = AppSessionScreen.debugClipboardImage;
  final previousFiles = AppSessionScreen.debugClipboardFiles;
  AppSessionScreen.debugClipboardImage = () async => image;
  AppSessionScreen.debugClipboardFiles = () async => files;
  addTearDown(() {
    AppSessionScreen.debugClipboardImage = previousImage;
    AppSessionScreen.debugClipboardFiles = previousFiles;
  });
}

Future<void> paste(WidgetTester t) async {
  await t.tap(find.byKey(const Key('composer-input')));
  await t.pump();
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await t.sendKeyEvent(LogicalKeyboardKey.keyV);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await frames(t);
}

/// Fake file picker returning [files], restored afterwards.
void fakePicker(List<MemXFile> files) {
  final previous = fsel.FileSelectorPlatform.instance;
  fsel.FileSelectorPlatform.instance = FakeFileSelector()..files = files;
  addTearDown(() => fsel.FileSelectorPlatform.instance = previous);
}

AppEvent permission(String handle, String options) => AppEvent(
  kind: agentPermissionKind,
  threadId: 'ses-1',
  requestId: handle,
  title: 'Run ls',
  raw: '{"threadId":"ses-1","toolCall":{"title":"Run ls"},"options":$options}',
);

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('reopening an ACP session makes no native metadata call', (
    t,
  ) async {
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    expect(api.threadMetadataCalls, isEmpty);
    expect(api.threadReads, contains('ses-1'));
    expect(api.modelListCalls, 0, reason: 'no invented model catalog');
    expect(api.rateLimitCalls, 0);
  });

  testWidgets('Codex still runs the native metadata check before resuming', (
    t,
  ) async {
    final api = AcpApi();
    await open(t, api, codex, thread: 'ses-1');
    expect(api.threadMetadataCalls, contains(codex));
  });

  testWidgets('the fake refuses native metadata for non-native protocols', (
    t,
  ) async {
    final api = FakeBridgeApi();
    await expectLater(api.appThreadMetadata(acp, 'x'), throwsStateError);
  });

  testWidgets('ACP has no live voice, dictation, presets or model chip', (
    t,
  ) async {
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    expect(find.byKey(const Key('voice-start')), findsNothing);
    expect(find.byType(DictationButton), findsNothing);
    expect(find.byKey(const Key('permission-chip')), findsNothing);
    expect(find.byKey(const Key('fast-mode-btn')), findsNothing);
    expect(find.byKey(const Key('model-chip')), findsNothing);
    await t.tap(find.byKey(const Key('attach-menu-btn')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('dictate-menu')), findsNothing);
    expect(
      find.byKey(const Key('attach-btn')),
      findsNothing,
      reason: 'the agent did not advertise image prompts',
    );
  });

  testWidgets('Codex keeps voice and dictation', (t) async {
    final api = AcpApi();
    await open(t, api, codex);
    expect(find.byKey(const Key('voice-start')), findsOneWidget);
  });

  testWidgets('agent options render as offered and answer the exact id', (
    t,
  ) async {
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    api.pushEvent(
      acp,
      permission(
        'h1',
        '[{"optionId":"opt:1 ✓","name":"Allow once","kind":"allow_once"},'
            '{"optionId":"later","name":"Ask me later","kind":"future_kind"},'
            '{"optionId":"no","name":"Reject","kind":"reject_once"}]',
      ),
    );
    await frames(t);
    expect(find.byKey(const Key('agent-permission-card')), findsOneWidget);
    expect(find.byKey(const Key('approval-card')), findsNothing);
    expect(find.text('Run ls'), findsWidgets);
    // Agent order and labels, unknown kinds included.
    final labels = [
      for (var i = 0; i < 3; i++)
        (t
                    .widget<ButtonStyleButton>(
                      find.byKey(Key('agent-permission-option-$i')),
                    )
                    .child!
                as Text)
            .data,
    ];
    expect(labels, ['Allow once', 'Ask me later', 'Reject']);
    await t.tap(find.byKey(const Key('agent-permission-option-0')));
    await frames(t);
    expect(api.lastApprovalDecision, 'opt:1 ✓');
    expect(find.byKey(const Key('agent-permission-card')), findsNothing);
  });

  test('malformed display details never hide a valid offered option', () {
    const valid = '{"optionId":"opt:✓ 1","name":"Allow","kind":"allow_once"}';
    AgentPermissionRequest parse(String tool, {String options = '[$valid]'}) =>
        AgentPermissionRequest.parse(
          AppEvent(
            kind: agentPermissionKind,
            title: 'Fallback',
            raw: '{"toolCall":$tool,"options":$options}',
          ),
        );
    for (final tool in [
      '{"locations":7}',
      '{"title":7}',
      '{"locations":{"path":"/w"},"title":["x"],"rawInput":"text"}',
      '{"locations":[7,null,{"path":7},{"line":1}]}',
      '7',
      '[]',
      'null',
    ]) {
      final request = parse(tool);
      expect(request.title, 'Fallback', reason: tool);
      expect(request.detail, isEmpty, reason: tool);
      expect(
        [for (final o in request.options) (o.id, o.name, o.kind)],
        [('opt:✓ 1', 'Allow', 'allow_once')],
        reason: tool,
      );
    }
    // Valid details are kept beside malformed siblings.
    final mixed = parse(
      '{"title":"Edit a.txt","locations":[7,{"path":"/w/a.txt"}],'
      '"rawInput":{"path":"/w/a.txt"}}',
    );
    expect(mixed.title, 'Edit a.txt');
    expect(mixed.detail, startsWith('/w/a.txt\n{'));
    expect(mixed.detail, contains('"path": "/w/a.txt"'));
    // Text content is shown (Grok's plan to approve); other blocks are not.
    final plan = parse(
      '{"title":"Plan","content":[{"type":"content","content":'
      '{"type":"text","text":"1. do it"}},{"type":"diff","path":"/w"},7]}',
    );
    expect(plan.detail, '1. do it');
    // Malformed option lists or entries are left out, never repaired.
    for (final options in ['7', '{"optionId":"x"}', 'null']) {
      expect(parse('{}', options: options).options, isEmpty, reason: options);
    }
    final kept = parse(
      '{}',
      options:
          '[7,{"optionId":7,"name":"Bad","kind":"allow_once"},$valid,'
          '{"optionId":"later","name":"Later","kind":"future_kind"}]',
    );
    expect(
      [for (final o in kept.options) (o.id, o.kind)],
      [('opt:✓ 1', 'allow_once'), ('later', 'future_kind')],
    );
  });

  testWidgets('a request with malformed details still answers its option', (
    t,
  ) async {
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    api.pushEvent(
      acp,
      const AppEvent(
        kind: agentPermissionKind,
        threadId: 'ses-1',
        requestId: 'h-bad',
        title: 'Run ls',
        raw:
            '{"threadId":"ses-1","toolCall":{"title":7,"locations":7},'
            '"options":[{"optionId":"opt:1 ✓","name":"Allow once",'
            '"kind":"allow_once"}]}',
      ),
    );
    await frames(t);
    expect(find.byKey(const Key('agent-permission-card')), findsOneWidget);
    expect(find.text('Run ls'), findsWidgets);
    expect(t.takeException(), isNull);
    expect(api.lastApprovalDecision, isNull, reason: 'never auto-answered');
    await t.tap(find.byKey(const Key('agent-permission-option-0')));
    await frames(t);
    expect(api.lastApprovalRequestId, 'h-bad');
    expect(api.lastApprovalDecision, 'opt:1 ✓');
    expect(find.byKey(const Key('agent-permission-card')), findsNothing);
  });

  testWidgets('remembering choices asks first', (t) async {
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    api.pushEvent(
      acp,
      permission(
        'h2',
        '[{"optionId":"always","name":"Always allow","kind":"allow_always"}]',
      ),
    );
    await frames(t);
    await t.tap(find.byKey(const Key('agent-permission-option-0')));
    await frames(t);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(api.lastApprovalDecision, isNull);
    await t.tap(find.byKey(const Key('agent-permission-remember-confirm')));
    await frames(t);
    expect(api.lastApprovalDecision, 'always');
  });

  testWidgets('a resolved agent request drops its card', (t) async {
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    api.pushEvent(
      acp,
      permission('h3', '[{"optionId":"a","name":"Allow","kind":"allow_once"}]'),
    );
    await frames(t);
    api.pushEvent(
      acp,
      const AppEvent(
        kind: 'serverRequest/resolved',
        threadId: 'ses-1',
        raw: '{"threadId":"ses-1","requestId":"h3"}',
      ),
    );
    await frames(t);
    expect(find.byKey(const Key('agent-permission-card')), findsNothing);
    expect(api.lastApprovalDecision, isNull);
  });

  testWidgets('per-session agent options send opaque value ids', (t) async {
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    api.sessionSettings['$acp|ses-1'] = const SessionSettings(
      configOptions: [
        SessionConfigOption(
          id: 'model',
          name: 'Model',
          category: 'model',
          currentValue: 'fast-1',
          values: [
            SessionConfigValue(value: 'fast-1', name: 'Fast'),
            SessionConfigValue(value: 'large-2', name: 'Two', group: 'Large'),
          ],
        ),
      ],
      currentMode: 'ask',
      modes: [
        SessionMode(id: 'ask', name: 'Ask'),
        SessionMode(id: 'code', name: 'Code'),
      ],
    );
    await open(t, api, acp, thread: 'ses-1');
    expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
    expect(find.text('Fast'), findsOneWidget);
    await t.tap(find.byKey(const Key('agent-config-model')));
    await t.pumpAndSettle();
    await t.tap(find.text('Large · Two').last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('agent-mode')));
    await t.pumpAndSettle();
    await t.tap(find.text('Code').last);
    await t.pumpAndSettle();
    expect(api.sessionConfigCalls, [
      ('ses-1', 'model', 'large-2'),
      ('ses-1', 'mode', 'code'),
    ]);
  });

  testWidgets('a routine agent state change keeps the connection', (t) async {
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    final connects = api.appConnectCount;
    api.pushEvent(
      acp,
      const AppEvent(
        kind: 'acp/host/state',
        raw: '{"phase":"ready","authRequired":false,"connected":true}',
      ),
    );
    await frames(t);
    expect(api.appConnectCount, connects);
  });

  testWidgets('losing the agent host reconnects and re-reads the session', (
    t,
  ) async {
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    final connects = api.appConnectCount;
    final reads = api.threadReads.where((id) => id == 'ses-1').length;
    api.pushEvent(
      acp,
      const AppEvent(kind: 'acp/host/state', raw: '{"connected":false}'),
    );
    await frames(t);
    expect(api.appConnectCount, greaterThan(connects));
    expect(
      api.threadReads.where((id) => id == 'ses-1').length,
      greaterThan(reads),
    );
  });

  testWidgets('a replaced agent host re-reads the session', (t) async {
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    final reads = api.threadReads.where((id) => id == 'ses-1').length;
    api.pushEvent(
      acp,
      const AppEvent(
        kind: 'acp/host/state',
        raw: '{"generation":4,"connected":true,"replaced":true}',
      ),
    );
    await frames(t);
    expect(
      api.threadReads.where((id) => id == 'ses-1').length,
      greaterThan(reads),
    );
  });

  testWidgets('a late completion of an earlier turn keeps the running one', (
    t,
  ) async {
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    api.pushEvent(
      acp,
      const AppEvent(
        kind: 'turn/started',
        threadId: 'ses-1',
        raw: '{"threadId":"ses-1","turnId":"B","turn":{"id":"B"}}',
      ),
    );
    await frames(t);
    expect(find.byKey(const Key('stop-btn')), findsOneWidget);
    // A recovery reports that the previous turn A finished.
    api.pushEvent(
      acp,
      const AppEvent(
        kind: 'turn/completed',
        threadId: 'ses-1',
        raw: '{"threadId":"ses-1","turn":{"id":"A","status":"completed"}}',
      ),
    );
    await frames(t);
    expect(
      find.byKey(const Key('stop-btn')),
      findsOneWidget,
      reason: 'B is still running',
    );
    await t.tap(find.byKey(const Key('stop-btn')));
    await frames(t);
    expect(api.lastInterruptTurnId, 'B', reason: 'Stop targets B, not A');
    api.pushEvent(
      acp,
      const AppEvent(
        kind: 'turn/completed',
        threadId: 'ses-1',
        raw: '{"threadId":"ses-1","turn":{"id":"B","status":"interrupted"}}',
      ),
    );
    await frames(t);
    expect(find.byKey(const Key('stop-btn')), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('messages sent elsewhere show live once; one sent here shows '
      'once', (t) async {
    final api = AcpApi()
      ..acpCapabilities[acp] = negotiated
      ..autoCompleteTurn = false;
    // Titled, so no message text doubles as its title.
    api.appThreads.add(
      const ThreadMeta(id: 'ses-1', preview: 'Work', cwd: '/w', updatedAt: 1),
    );
    await open(t, api, acp, thread: 'ses-1');
    AppEvent user(String id, String text, Object? sender) => AppEvent(
      kind: 'item/completed',
      threadId: 'ses-1',
      itemId: id,
      itemType: 'userMessage',
      text: text,
      raw: jsonEncode({'threadId': 'ses-1', 'turnId': 'F', 'clientId': sender}),
    );
    // Another device's prompt (sent without a client id) and supplement
    // (with its own), and the same item again.
    for (final event in [
      const AppEvent(
        kind: 'turn/started',
        threadId: 'ses-1',
        raw: '{"threadId":"ses-1","turnId":"F","clientId":null}',
      ),
      user('F:u', 'from the phone', null),
      user('F:s1', 'and one more', 'a-phone-id'),
      user('F:s1', 'and one more', 'a-phone-id'),
    ]) {
      api.pushEvent(acp, event);
    }
    await frames(t);
    expect(find.text('from the phone', findRichText: true), findsOneWidget);
    expect(find.text('and one more', findRichText: true), findsOneWidget);
    // Its turn runs here like any other: Stop names it.
    await t.tap(find.byKey(const Key('stop-btn')));
    await frames(t);
    expect(api.lastInterruptTurnId, 'F');
    api.pushEvent(
      acp,
      const AppEvent(
        kind: 'turn/completed',
        threadId: 'ses-1',
        raw: '{"turn":{"id":"F","status":"interrupted"}}',
      ),
    );
    await frames(t);

    // A message sent here: the host's item names it, so its own copy is it.
    await t.enterText(find.byKey(const Key('composer-input')), 'from here');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await frames(t);
    expect(api.lastTurnClientId, isNotNull);
    expect(find.text('from here', findRichText: true), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('a new command list from the agent replaces the shown one', (
    t,
  ) async {
    final api = AcpApi()
      ..acpCapabilities[acp] = negotiatedAcpCapabilities(
        providerName: 'Grok',
        commands: true,
      )
      ..agentCommands = const [AgentCommand(name: 'old')];
    await open(t, api, acp, thread: 'ses-1');
    await t.enterText(find.byKey(const Key('composer-input')), '/');
    await frames(t);
    expect(find.byKey(const Key('command-old')), findsOneWidget);
    // The host state that carries the agent's new list.
    api.agentCommands = const [AgentCommand(name: 'compact')];
    api.pushEvent(
      acp,
      const AppEvent(
        kind: 'acp/host/state',
        raw: '{"phase":{"state":"ready"}}',
      ),
    );
    await frames(t);
    expect(find.byKey(const Key('command-compact')), findsOneWidget);
    expect(find.byKey(const Key('command-old')), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });
  _registerAttachments();
  _registerOmissions();

  testWidgets('an agent that reports no options shows no option chips', (
    t,
  ) async {
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    expect(find.byKey(const Key('agent-session-options')), findsNothing);
  });
}
