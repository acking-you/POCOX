import 'dart:async';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart'
    as fsel;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/composer_harness.dart';
import 'support/screen_harness.dart';

class _UploadingApi extends FakeBridgeApi {
  final upload = Completer<String>();

  @override
  Future<String> metaUploadFileScoped(
    String serviceKey,
    String fileName,
    Uint8List bytes,
    String context,
  ) => upload.future;
}

class _StartingApi extends FakeBridgeApi {
  final start = Completer<void>();
  bool starting = false;
  Completer<void>? turnAck;
  final sentTo = <String>[];

  @override
  Future<String> appThreadStart(
    String serviceKey, {
    String? model,
    String? cwd,
    String? approvalPolicy,
    String? approvalsReviewer,
    String? serviceTier,
    String? sandbox,
  }) async {
    starting = true;
    await start.future;
    return super.appThreadStart(
      serviceKey,
      model: model,
      cwd: cwd,
      approvalPolicy: approvalPolicy,
      approvalsReviewer: approvalsReviewer,
      serviceTier: serviceTier,
      sandbox: sandbox,
    );
  }

  @override
  Future<void> appTurnStart(
    String serviceKey,
    String threadId,
    String text, {
    List<String> images = const [],
    String? model,
    String? approvalPolicy,
    String? approvalsReviewer,
    String? serviceTier,
    String? sandbox,
    String? collaborationMode,
    String? reasoningEffort,
  }) async {
    sentTo.add(threadId);
    await super.appTurnStart(
      serviceKey,
      threadId,
      text,
      images: images,
      model: model,
      approvalPolicy: approvalPolicy,
      approvalsReviewer: approvalsReviewer,
      serviceTier: serviceTier,
      sandbox: sandbox,
      collaborationMode: collaborationMode,
      reasoningEffort: reasoningEffort,
    );
    if (turnAck != null) await turnAck!.future;
  }
}

class _DelayedFileSelector extends FakeFileSelector {
  final selection = Completer<List<fsel.XFile>>();

  @override
  Future<List<fsel.XFile>> openFiles({
    List<fsel.XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) => selection.future;
}

class _LateDefaultStartingApi extends _StartingApi {
  final project = Completer<ProjectConfig>();

  @override
  Future<ProjectConfig> metaProjectConfig(String serviceKey) => project.future;
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  Future<void> switchProject(WidgetTester t, String cwd) async {
    if (find.byKey(const Key('project-switcher-btn')).evaluate().isEmpty) {
      await t.longPress(find.byKey(Key('project-header-$cwd')));
      await composerFrames(t);
      await t.tap(find.text('New conversation in ${cwd.split('/').last}'));
    } else {
      await t.tap(find.byKey(const Key('project-switcher-btn')));
      await composerFrames(t);
      await t.tap(find.byKey(Key('project-menu-item-$cwd')));
    }
    await composerFrames(t);
  }

  testWidgets(
    'a project draft keeps its send lock when reopened before thread creation',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(1280, 900);
      addTearDown(t.view.reset);
      final api = _StartingApi()
        ..appThreads.addAll([
          const ThreadMeta(
            id: 'a',
            preview: 'Alpha history',
            cwd: '/alpha',
            updatedAt: 2,
          ),
          const ThreadMeta(
            id: 'b',
            preview: 'Beta history',
            cwd: '/beta',
            updatedAt: 1,
          ),
        ]);
      await mountComposer(t, api, thread: null, cwd: '/alpha');
      await t.enterText(composerInput, 'Start alpha');
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pump();
      await switchProject(t, '/beta');
      await switchProject(t, '/alpha');
      await t.enterText(composerInput, 'Alpha followup');
      await t.pump();
      expect(
        t.widget<IconButton>(find.byKey(const Key('send-btn'))).onPressed,
        isNull,
      );
      api.start.complete();
      await t.pumpAndSettle();
      expect(api.sentTo, ['thread-0']);
      expect(composerController(t).text, 'Alpha followup');
      expect(
        t.widget<IconButton>(find.byKey(const Key('send-btn'))).onPressed,
        isNotNull,
      );
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pumpAndSettle();
      expect(api.sentTo, ['thread-0', 'thread-0']);
      expect(api.appThreads, hasLength(3));
    },
  );

  testWidgets(
    'reopened project drains queued input after the pending first send',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(1280, 900);
      addTearDown(t.view.reset);
      final api = _StartingApi()
        ..turnAck = Completer<void>()
        ..appThreads.addAll([
          const ThreadMeta(
            id: 'a',
            preview: 'Alpha history',
            cwd: '/alpha',
            updatedAt: 2,
          ),
          const ThreadMeta(
            id: 'b',
            preview: 'Beta history',
            cwd: '/beta',
            updatedAt: 1,
          ),
        ]);
      await mountComposer(t, api, thread: null, cwd: '/alpha');
      await t.enterText(composerInput, 'Start alpha');
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pump();
      await switchProject(t, '/beta');
      await switchProject(t, '/alpha');
      await t.enterText(composerInput, 'Queued alpha');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(find.byKey(const Key('queued-0')), findsOneWidget);
      api.start.complete();
      await composerFrames(t);
      expect(api.sentTo, ['thread-0']);
      api.turnAck!.complete();
      await t.pumpAndSettle();
      expect(api.sentTo, ['thread-0', 'thread-0']);
      expect(api.lastTurnText, 'Queued alpha');
      expect(find.byKey(const Key('queued-0')), findsNothing);
      expect(api.appThreads, hasLength(3));
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'late defaults cannot replace a draft whose first send is pending',
    (t) async {
      final api = _LateDefaultStartingApi();
      await mountComposer(t, api, thread: null, cwd: '/alpha');
      await t.enterText(composerInput, 'Saved alpha draft');
      await t.pumpWidget(
        host(const SizedBox(), api, locale: const Locale('en')),
      );
      await mountComposer(t, api, thread: null, settle: false);
      await t.enterText(composerInput, 'Send in the current working directory');
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pump();
      expect(api.starting, isTrue);
      api.project.complete(const ProjectConfig(defaultProject: '/alpha'));
      await t.pumpAndSettle();
      expect(composerController(t).text, isEmpty);
      api.start.complete();
      await t.pumpAndSettle();
      expect(api.sentTo, ['thread-0']);
      expect(api.lastCwd, isNull);
      await t.enterText(composerInput, 'Followup');
      await t.pump();
      expect(
        t.widget<IconButton>(find.byKey(const Key('send-btn'))).onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('new project drafts keep uploads in their originating project', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1280, 900);
    addTearDown(t.view.reset);
    final api = _UploadingApi()
      ..appThreads.add(
        const ThreadMeta(id: 'b', preview: 'Beta', cwd: '/beta', updatedAt: 0),
      );
    final previous = fsel.FileSelectorPlatform.instance;
    fsel.FileSelectorPlatform.instance = FakeFileSelector()
      ..files = [
        MemXFile(Uint8List.fromList([1, 2]), 'alpha.txt'),
      ];
    addTearDown(() => fsel.FileSelectorPlatform.instance = previous);
    await mountComposer(t, api, thread: null, cwd: '/alpha');
    await t.tap(find.byKey(const Key('attach-menu-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('attach-file-btn')));
    await t.pump();
    await switchProject(t, '/beta');
    await t.enterText(composerInput, 'Beta draft');
    api.upload.complete('/host/alpha.txt');
    await t.pumpAndSettle();
    expect(find.text('alpha.txt'), findsNothing);
    await switchProject(t, '/alpha');
    expect(find.text('alpha.txt'), findsOneWidget);
    expect(composerController(t).text, isEmpty);
    await switchProject(t, '/beta');
    expect(composerController(t).text, 'Beta draft');
    expect(find.text('alpha.txt'), findsNothing);
  });

  testWidgets('a background first send adopts only its project draft', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1280, 900);
    addTearDown(t.view.reset);
    final api = _StartingApi()
      ..appThreads.add(
        const ThreadMeta(id: 'b', preview: 'Beta', cwd: '/beta', updatedAt: 0),
      );
    await mountComposer(t, api, thread: null, cwd: '/alpha');
    await t.enterText(composerInput, 'Start alpha');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pump();
    await t.enterText(composerInput, 'Alpha followup');
    await switchProject(t, '/beta');
    await t.enterText(composerInput, 'Beta draft');
    api.start.complete();
    await t.pumpAndSettle();
    expect(api.lastCwd, '/alpha');
    expect(api.sentTo, ['thread-0']);
    expect(composerController(t).text, 'Beta draft');
    await t.tap(find.byKey(const Key('conv-tile-thread-0')));
    await t.pumpAndSettle();
    expect(composerController(t).text, 'Alpha followup');
    await t.tap(find.byKey(const Key('new-conversation-btn')));
    await t.pumpAndSettle();
    expect(composerController(t).text, isEmpty);
    await switchProject(t, '/beta');
    expect(composerController(t).text, 'Beta draft');
  });

  testWidgets(
    'reopening the default project restores its existing unsent draft',
    (t) async {
      final api = FakeBridgeApi();
      api.projectConfigs[composerService] = const ProjectConfig(
        defaultProject: '/alpha',
      );
      await mountComposer(t, api, thread: null, cwd: '/alpha');
      await t.enterText(composerInput, 'Remember alpha');
      await t.pumpWidget(
        host(const SizedBox(), api, locale: const Locale('en')),
      );
      await mountComposer(t, api, thread: null);
      expect(composerController(t).text, 'Remember alpha');
      expect(find.text('alpha'), findsWidgets);
    },
  );

  testWidgets(
    'draft text and selection follow conversations and survive navigation',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(1280, 900);
      addTearDown(t.view.reset);
      final api = FakeBridgeApi()
        ..appThreads.addAll([
          const ThreadMeta(
            id: 'a',
            preview: 'Alpha',
            cwd: '/project',
            updatedAt: 0,
          ),
          const ThreadMeta(
            id: 'b',
            preview: 'Beta',
            cwd: '/project',
            updatedAt: 0,
          ),
        ]);
      await mountComposer(t, api);
      await t.enterText(composerInput, 'Unfinished alpha');
      const selection = TextSelection(baseOffset: 3, extentOffset: 8);
      composerController(t).selection = selection;
      await t.pump();
      expect(
        find.descendant(
          of: find.byKey(const Key('conv-tile-a')),
          matching: find.textContaining('Draft'),
        ),
        findsOneWidget,
      );
      await t.tap(find.byKey(const Key('conv-tile-b')));
      await t.pumpAndSettle();
      expect(composerController(t).text, isEmpty);
      await t.enterText(composerInput, 'Unfinished beta');
      await t.tap(find.byKey(const Key('conv-tile-a')));
      await t.pumpAndSettle();
      expect(composerController(t).text, 'Unfinished alpha');
      expect(composerController(t).selection, selection);
      await t.pumpWidget(
        host(const SizedBox(), api, locale: const Locale('en')),
      );
      await mountComposer(t, api);
      expect(composerController(t).text, 'Unfinished alpha');
      await mountComposer(t, api, service: 'pcx:other:app:default');
      expect(
        composerController(t).text,
        isEmpty,
        reason: 'Hosts must not share drafts.',
      );
      await mountComposer(t, api);
      expect(composerController(t).text, 'Unfinished alpha');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'a pending first send keeps its original conversation and draft',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(1280, 900);
      addTearDown(t.view.reset);
      final api = _StartingApi()
        ..appThreads.add(
          const ThreadMeta(
            id: 'b',
            preview: 'Beta',
            cwd: '/project',
            updatedAt: 0,
          ),
        );
      await mountComposer(t, api, thread: null);
      await t.enterText(composerInput, 'First message');
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pump();
      expect(api.starting, isTrue);
      await t.enterText(composerInput, 'Next draft for the new conversation');
      await t.tap(find.byKey(const Key('conv-tile-b')));
      await t.pumpAndSettle();
      await t.enterText(composerInput, 'Unfinished beta');
      api.start.complete();
      await t.pumpAndSettle();
      expect(api.sentTo, ['thread-0']);
      expect(composerController(t).text, 'Unfinished beta');
      // A second send must still target the conversation the user selected.
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pumpAndSettle();
      expect(api.sentTo, ['thread-0', 'b']);
      await t.enterText(composerInput, 'Keep beta');
      await t.tap(find.byKey(const Key('conv-tile-thread-0')));
      await t.pumpAndSettle();
      expect(composerController(t).text, 'Next draft for the new conversation');
      await t.tap(find.byKey(const Key('conv-tile-b')));
      await t.pumpAndSettle();
      expect(composerController(t).text, 'Keep beta');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'returning to a pending new conversation adopts its created thread',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(1280, 900);
      addTearDown(t.view.reset);
      final api = _StartingApi()
        ..appThreads.add(
          const ThreadMeta(
            id: 'b',
            preview: 'Beta',
            cwd: '/project',
            updatedAt: 0,
          ),
        );
      await mountComposer(t, api, thread: null, cwd: '/project');
      await t.enterText(composerInput, 'First message');
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pump();
      expect(api.starting, isTrue);
      await t.enterText(composerInput, 'Next message');
      await t.tap(find.byKey(const Key('conv-tile-b')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('new-conversation-btn')));
      await t.pumpAndSettle();
      api.start.complete();
      await t.pumpAndSettle();
      expect(composerController(t).text, 'Next message');
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pumpAndSettle();
      expect(api.sentTo, ['thread-0', 'thread-0']);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'a failed background first send restores only its original draft',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(1280, 900);
      addTearDown(t.view.reset);
      final api = _StartingApi()
        ..appThreads.add(
          const ThreadMeta(
            id: 'b',
            preview: 'Beta',
            cwd: '/project',
            updatedAt: 0,
          ),
        );
      await mountComposer(t, api, thread: null, cwd: '/project');
      await t.enterText(composerInput, 'First message');
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pump();
      expect(api.starting, isTrue);
      await t.enterText(composerInput, 'Next draft');
      await t.tap(find.byKey(const Key('conv-tile-b')));
      await t.pumpAndSettle();
      await t.enterText(composerInput, 'Unfinished beta');
      api.start.completeError(StateError('Thread creation failed'));
      await t.pumpAndSettle();
      expect(composerController(t).text, 'Unfinished beta');
      expect(api.sentTo, isEmpty);
      await t.tap(find.byKey(const Key('new-conversation-btn')));
      await t.pumpAndSettle();
      expect(composerController(t).text, 'First message\n\nNext draft');
      expect(
        t.widget<IconButton>(find.byKey(const Key('send-btn'))).onPressed,
        isNotNull,
      );
      expect(t.takeException(), isNull);
    },
  );

  // The native supplement fixture: a running conversation "a" (with "b"
  // beside it) whose supplement answer is held, and a file to attach.
  // The staged file's composer tile (the first attachment of the screen).
  final sentTile = find.byKey(const Key('attachment-0'));

  Future<(FakeBridgeApi, FakeFileSelector)> supplementFixture(
    WidgetTester t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1280, 900);
    addTearDown(t.view.reset);
    final api = FakeBridgeApi()
      ..steerGate = Completer<void>()
      ..readResult = const ThreadHistory(items: [], running: true)
      ..appThreads.addAll([
        const ThreadMeta(
          id: 'a',
          preview: 'Alpha',
          cwd: '/project',
          updatedAt: 0,
        ),
        const ThreadMeta(
          id: 'b',
          preview: 'Beta',
          cwd: '/project',
          updatedAt: 0,
        ),
      ]);
    final previous = fsel.FileSelectorPlatform.instance;
    final selector = FakeFileSelector()
      ..files = [
        MemXFile(Uint8List.fromList([1, 2]), 'sent.txt'),
      ];
    fsel.FileSelectorPlatform.instance = selector;
    addTearDown(() => fsel.FileSelectorPlatform.instance = previous);
    await mountComposer(t, api, settle: false);
    await t.tap(find.byKey(const Key('attach-menu-btn')));
    await composerFrames(t);
    await t.tap(find.byKey(const Key('attach-file-btn')));
    await composerFrames(t);
    // The composer's own tile for the staged file.
    expect(
      find.descendant(of: sentTile, matching: find.text('sent.txt')),
      findsOneWidget,
    );
    await t.tap(find.byKey(const Key('supplement-toggle')));
    await t.enterText(composerInput, 'Accepted supplement');
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pump();
    return (api, selector);
  }

  // Exactly one supplement left, carrying the accepted text and file.
  // The literal is the file-reference format (attachment_refs.dart), spelled
  // out rather than rebuilt with the production helper.
  void expectOneSupplement(FakeBridgeApi api) {
    expect(api.supplementCalls, hasLength(1));
    final (thread, _, text, images) = api.supplementCalls.single;
    expect(thread, 'a');
    expect(
      text,
      'Accepted supplement\n\n'
      "## Attached files (read them from this machine's filesystem):\n"
      '- /host/uploads/123/sent.txt',
    );
    expect(images, isEmpty);
    expect(api.lastSteerText, text, reason: 'native: through turn/steer');
  }

  testWidgets('an owned supplement clears exactly what it sent, keeping a '
      'later edit', (t) async {
    final (api, _) = await supplementFixture(t);
    await t.enterText(composerInput, 'Later edit');
    await t.pump();
    api.steerGate!.complete();
    await composerFrames(t);
    expectOneSupplement(api);
    expect(
      composerController(t).text,
      'Later edit',
      reason: 'not what was sent',
    );
    expect(sentTile, findsNothing, reason: 'its file left the composer');
    expect(
      find.byKey(const Key('attachment-remove-0')),
      findsNothing,
      reason: 'nothing of it is left to remove',
    );
    // The accepted user message keeps its file reference: the one remaining
    // `sent.txt` is the transcript's, not a composer tile.
    expect(find.text('sent.txt'), findsOneWidget, reason: 'transcript row');
    expect(api.turnStartCount, 0, reason: 'never sent again as a prompt');
    expect(t.takeException(), isNull);
  });

  // Leaving the conversation ends the request's ownership of its view: its
  // late (accepted) answer cannot tell which input it consumed, so the
  // draft, its attachments and the queue stay as they are — nothing is
  // cleared, queued or sent again.
  for (final returnBeforeAck in [false, true]) {
    testWidgets(
      'a supplement answered after leaving its conversation keeps its exact '
      'input (return before ack: $returnBeforeAck)',
      (t) async {
        final (api, selector) = await supplementFixture(t);
        await t.tap(find.byKey(const Key('conv-tile-b')));
        await composerFrames(t);
        await t.enterText(composerInput, 'Unfinished beta');
        if (returnBeforeAck) {
          await t.tap(find.byKey(const Key('conv-tile-a')));
          await composerFrames(t);
          await t.enterText(composerInput, 'Newer alpha draft');
          selector.files = [
            MemXFile(Uint8List.fromList([3]), 'new.txt'),
          ];
          await t.tap(find.byKey(const Key('attach-menu-btn')));
          await composerFrames(t);
          await t.tap(find.byKey(const Key('attach-file-btn')));
          await composerFrames(t);
        }
        api.steerGate!.complete();
        await composerFrames(t);
        if (!returnBeforeAck) {
          expect(composerController(t).text, 'Unfinished beta');
          await t.tap(find.byKey(const Key('conv-tile-a')));
          await composerFrames(t);
        }
        expect(
          composerController(t).text,
          returnBeforeAck ? 'Newer alpha draft' : 'Accepted supplement',
        );
        expect(find.text('sent.txt'), findsOneWidget, reason: 'kept');
        if (returnBeforeAck) {
          expect(find.text('new.txt'), findsOneWidget, reason: 'added after');
        }
        await t.tap(find.byKey(const Key('conv-tile-b')));
        await composerFrames(t);
        expect(composerController(t).text, 'Unfinished beta');
        expectOneSupplement(api);
        expect(api.turnStartCount, 0, reason: 'nothing queued or replayed');
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a pending picker survives leaving and returning to an empty draft',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(1280, 900);
      addTearDown(t.view.reset);
      final api = FakeBridgeApi()
        ..appThreads.addAll([
          const ThreadMeta(
            id: 'a',
            preview: 'Alpha',
            cwd: '/project',
            updatedAt: 0,
          ),
          const ThreadMeta(
            id: 'b',
            preview: 'Beta',
            cwd: '/project',
            updatedAt: 0,
          ),
        ]);
      final previous = fsel.FileSelectorPlatform.instance;
      final selector = _DelayedFileSelector();
      fsel.FileSelectorPlatform.instance = selector;
      addTearDown(() => fsel.FileSelectorPlatform.instance = previous);
      await mountComposer(t, api);
      await t.tap(find.byKey(const Key('attach-menu-btn')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('attach-file-btn')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('conv-tile-b')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('conv-tile-a')));
      await t.pumpAndSettle();
      selector.selection.complete([
        MemXFile(Uint8List.fromList([1, 2]), 'late.txt'),
      ]);
      await t.pumpAndSettle();
      expect(find.text('late.txt'), findsOneWidget);
      expect(
        t.widget<IconButton>(find.byKey(const Key('send-btn'))).onPressed,
        isNotNull,
      );
      await t.enterText(composerInput, 'Keep this attachment');
      await t.pumpWidget(
        host(const SizedBox(), api, locale: const Locale('en')),
      );
      await mountComposer(t, api);
      expect(find.text('late.txt'), findsOneWidget);
      expect(composerController(t).text, 'Keep this attachment');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'an upload finishes in its original draft after screen navigation',
    (t) async {
      final api = _UploadingApi();
      final previous = fsel.FileSelectorPlatform.instance;
      final selector = FakeFileSelector()
        ..files = [
          MemXFile(Uint8List.fromList([1, 2]), 'draft.txt'),
        ];
      fsel.FileSelectorPlatform.instance = selector;
      addTearDown(() => fsel.FileSelectorPlatform.instance = previous);
      await mountComposer(t, api);
      await t.tap(find.byKey(const Key('attach-menu-btn')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('attach-file-btn')));
      await t.pump();
      expect(find.byKey(const Key('attachment-0')), findsOneWidget);
      await t.pumpWidget(
        host(const SizedBox(), api, locale: const Locale('en')),
      );
      api.upload.complete('/host/draft.txt');
      await t.pump();
      await mountComposer(t, api);
      expect(find.text('draft.txt'), findsOneWidget);
      expect(
        t.widget<IconButton>(find.byKey(const Key('send-btn'))).onPressed,
        isNotNull,
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'queue action and stop coexist; queue flushing preserves a newer draft',
    (t) async {
      final api = FakeBridgeApi()..autoCompleteTurn = false;
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(360, 800);
      addTearDown(t.view.reset);
      await mountComposer(t, api);
      await t.enterText(composerInput, 'First');
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pump();
      expect(find.byKey(const Key('stop-btn')), findsOneWidget);
      await t.enterText(composerInput, 'Second');
      await t.pump();
      expect(
        t.widget<IconButton>(find.byKey(const Key('send-btn'))).tooltip,
        'Queue for next turn',
      );
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pump();
      expect(find.byKey(const Key('queued-0')), findsOneWidget);
      expect(api.lastTurnText, 'First');
      await t.enterText(composerInput, 'Still editing the third');
      api.pushEvent(
        composerService,
        const AppEvent(kind: 'turn/completed', threadId: 'a', raw: '{}'),
      );
      await t.pump();
      expect(api.lastTurnText, 'Second');
      expect(composerController(t).text, 'Still editing the third');
      expect(find.byKey(const Key('queued-0')), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
}
