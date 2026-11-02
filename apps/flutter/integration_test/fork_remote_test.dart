// Live desktop acceptance of forking: conversation screen -> real bridge -> relay
// -> a remote host's external Codex, and back.
// Run with --dart-define-from-file containing POCOX_RELAY, POCOX_KEY,
// POCOX_SERVICE and POCOX_CWD (a folder on that host). This test creates sessions
// and sends prompts, so point the host at an isolated CODEX_HOME whose provider is
// a local fixture, as `thread_fork_live_tests` does.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/bridge_api_rust.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/rust/api/bridge.dart' as frb;
import 'package:pocox/src/rust/frb_generated.dart';
import 'package:pocox/src/screens/app_session_screen.dart';
import 'package:pocox/src/ui_prefs.dart';
import 'package:window_manager/window_manager.dart';

const _relay = String.fromEnvironment('POCOX_RELAY');
const _key = String.fromEnvironment('POCOX_KEY');
const _service = String.fromEnvironment('POCOX_SERVICE');
const _cwd = String.fromEnvironment('POCOX_CWD');

const _sourcePrompt = 'fork-acceptance-source';
const _branchPrompt = 'fork-acceptance-branch';

class _MemoryPrefs extends UiPrefsStore {
  @override
  Future<UiPrefs> load() async => const UiPrefs();

  @override
  Future<void> save(UiPrefs prefs) async {}
}

class _ObservedBridge extends RustBridgeApi {
  final forks = <ThreadForkResult>[];

  @override
  Future<ThreadForkResult> appThreadFork(
    String serviceKey,
    String threadId, {
    String? throughTurnId,
  }) async {
    final fork = await super.appThreadFork(
      serviceKey,
      threadId,
      throughTurnId: throughTurnId,
    );
    forks.add(fork);
    return fork;
  }
}

Future<void> _until(
  WidgetTester tester,
  String what,
  bool Function() ready,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue, reason: 'timed out waiting for $what');
  await Future<void>.delayed(const Duration(milliseconds: 200));
}

/// Wait until the host reports [thread] idle after [turns] turns.
Future<ThreadHistory> _settled(BridgeApi api, String thread, int turns) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (true) {
    try {
      final history = await api.appThreadRead(_service, thread);
      if (!history.running &&
          history.turns.length == turns &&
          history.turns.last.assistantText.isNotEmpty) {
        return history;
      }
    } catch (_) {
      // A thread with its first turn just started may not be readable yet.
    }
    expect(
      DateTime.now().isBefore(deadline),
      isTrue,
      reason: '$thread did not settle at $turns turns',
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'a remote conversation forks from the screen and both go on',
    (tester) async {
      if ([_relay, _key, _service, _cwd].any((value) => value.isEmpty)) {
        markTestSkipped('isolated live-fork configuration not provided');
        return;
      }
      await RustLib.init();
      await windowManager.ensureInitialized();
      await windowManager.show();
      final dir = await Directory.systemTemp.createTemp('pcx-fork-it-');
      await frb.initBridge(supportDir: dir.path);
      await frb.setRelay(relay: _relay);
      await frb.setKey(key: _key);
      final api = _ObservedBridge();
      await api.appConnect(_service, 0);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await api.appDisconnect(_service);
      });
      expect(api.appCapabilities(_service).fork, isTrue);

      final source = await api.appThreadStart(_service, cwd: _cwd);
      await api.appTurnStart(_service, source, _sourcePrompt);
      await _settled(api, source, 1);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bridgeApiProvider.overrideWithValue(api),
            uiPrefsProvider.overrideWith(_MemoryPrefs.new),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AppSessionScreen(
              serviceKey: _service,
              threadId: source,
              home: true,
            ),
          ),
        ),
      );
      final turnAction = find.byKey(const Key('message-fork'));
      await _until(
        tester,
        'the finished turn to offer itself',
        () => turnAction.evaluate().isNotEmpty,
      );

      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await _until(
        tester,
        'the conversation menu',
        () => find.byKey(const Key('session-fork')).evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(const Key('session-fork')));
      await _until(
        tester,
        'the confirmation',
        () => find.byKey(const Key('fork-confirm')).evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(const Key('fork-confirm')));
      await _until(tester, 'the host to answer', () => api.forks.isNotEmpty);

      final fork = api.forks.single.thread!;
      expect(fork.id, isNot(source));
      expect(fork.forkedFromId, source);
      expect(fork.parentThreadId, isNull);
      expect(api.forks.single.boundaryConfirmed, isTrue);
      final mark = find.byKey(const Key('fork-source-mark'));
      await _until(
        tester,
        'the fork to open',
        () => mark.evaluate().isNotEmpty,
      );
      await _until(
        tester,
        'the inherited conversation',
        () => find.textContaining(_sourcePrompt).evaluate().isNotEmpty,
      );
      final metadata = await api.appThreadMetadata(_service, fork.id);
      expect(metadata?.forkedFromId, source);

      // The new conversation takes a turn of its own from the real composer.
      final composer = find.byKey(const Key('composer-input'));
      await _until(
        tester,
        'the composer',
        () => composer.evaluate().isNotEmpty,
      );
      await tester.enterText(composer, _branchPrompt);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('send-btn')));
      await _settled(api, fork.id, 2);

      // The source is where it was: reachable, and without the fork's turn.
      await tester.tap(mark);
      await _until(
        tester,
        'the source to open',
        () => mark.evaluate().isEmpty && composer.evaluate().isNotEmpty,
      );
      final original = await _settled(api, source, 1);
      expect(
        original.items.any((item) => item.text.contains(_branchPrompt)),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
