import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/screens/app_session_screen.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/voice/voice_controller.dart';
import 'package:pocox/src/voice/voice_transport.dart';
import 'package:pocox/src/voice/voice_widgets.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart' show unfoldComposer;
import 'support/ui_preview.dart';

const _service = 'pcx:host:app:default';

class _VoiceApi extends FakeBridgeApi {
  final calls = <(String, Map<String, dynamic>)>[];
  Completer<void>? startAck;
  Completer<void>? threadAck;
  Completer<void>? stopAck;
  bool rejectStart = false;
  @override
  Future<String> appRealtimeRequest(
    String serviceKey,
    String method,
    String paramsJson,
  ) async {
    final params = jsonDecode(paramsJson) as Map<String, dynamic>;
    calls.add((method, params));
    switch (method) {
      case 'thread/realtime/listVoices':
        return jsonEncode({
          'voices': {
            'v1': ['cove', 'breeze'],
            'v2': ['marin'],
            'defaultV1': 'cove',
          },
        });
      case 'thread/start':
        await threadAck?.future;
        appThreads.add(
          const ThreadMeta(
            id: 'voice',
            preview: '',
            cwd: '/repo',
            updatedAt: 1,
            threadSource: 'pocox-voice',
          ),
        );
        return '{"thread":{"id":"voice","cwd":"/repo"}}';
      case 'thread/realtime/start':
        if (rejectStart) {
          throw StateError('Voice is unavailable for this account');
        }
        await startAck?.future;
      case 'thread/realtime/stop':
        await stopAck?.future;
      case 'thread/timeline/list':
        return jsonEncode({
          'data': [
            {
              'type': 'realtime',
              'position': 1,
              'item': {
                'id': 'speech',
                'type': 'transcriptSegment',
                'role': 'user',
                'text': 'Saved spoken request',
              },
            },
          ],
          'nextCursor': null,
        });
    }
    return '{}';
  }

  void event(
    String kind,
    Map<String, dynamic> data, {
    String thread = 'voice',
  }) => pushEvent(
    _service,
    AppEvent(
      kind: 'thread/realtime/$kind',
      threadId: thread,
      raw: jsonEncode(data),
    ),
  );
}

class _Media implements VoiceTransport {
  bool closed = false;
  bool muted = false;
  String? answerSdp;
  Completer<String>? pendingOffer;
  late VoidCallback connected;
  late void Function(String) failure;
  VoidCallback? interrupted;
  bool speakerSuppressed = false;
  final suppressions = <bool>[];
  @override
  Future<String> offer({
    required void Function() onConnected,
    required void Function(String) onFailure,
    void Function()? onInterrupted,
  }) async {
    connected = onConnected;
    failure = onFailure;
    interrupted = onInterrupted;
    return pendingOffer == null ? 'offer' : await pendingOffer!.future;
  }

  @override
  Future<void> answer(String sdp) async {
    answerSdp = sdp;
    connected();
  }

  @override
  void setMuted(bool value) {
    muted = value;
  }

  @override
  void setSpeakerSuppressed(bool value) {
    speakerSuppressed = value;
    suppressions.add(value);
  }

  /// What [levels] reports; null until a test sets it.
  AudioLevels? level;

  @override
  Future<AudioLevels?> levels() async => level;

  @override
  Future<void> close() async {
    closed = true;
  }
}

Future<void> _tick() => Future<void>.delayed(Duration.zero);

/// Some frames of a live call, so its orb and captions settle into what a
/// person would see rather than the first frame of each change.
Future<void> _frames(WidgetTester t) async {
  for (var i = 0; i < 15; i++) {
    await t.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  setUpAll(loadPreviewFonts);
  test('voice source survives renaming', () {
    const t = ThreadMeta(
      id: 'v',
      preview: '',
      cwd: '',
      updatedAt: 0,
      threadSource: 'pocox-voice',
    );
    expect(t.withName('Renamed').isVoice, isTrue);
  });
  test(
    'SDP, model, voice, mute and transcript use the selected thread',
    () async {
      final api = _VoiceApi();
      final media = _Media();
      final c = VoiceController(
        api: api,
        serviceKey: _service,
        createTransport: () => media,
      );
      await c.start('voice', model: 'voice-model', voice: 'cove');
      expect(c.phase, VoicePhase.connecting);
      final params = api.calls.single.$2;
      expect(params['transport'], {'type': 'webrtc', 'sdp': 'offer'});
      expect(params['model'], 'voice-model');
      expect(params['voice'], 'cove');
      expect(params['version'], 'v3');
      expect(params['clientManagedHandoffs'], false);
      api.event('sdp', {'sdp': 'foreign'}, thread: 'other');
      api.event('sdp', {'sdp': 'answer'});
      api.event('transcript/delta', {'role': 'user', 'delta': 'Hello'});
      await _tick();
      expect(media.answerSdp, 'answer');
      expect(c.phase, VoicePhase.active);
      expect(c.partial['user'], 'Hello');
      c.toggleMuted();
      expect(media.muted, isTrue);
      api.event('transcript/done', {'role': 'user', 'text': 'Hello world'});
      await _tick();
      expect(c.partial, isEmpty);
      expect(c.transcript.single.text, 'Hello world');
      await c.stop();
      expect(media.closed, isTrue);
      expect(api.calls.last.$1, 'thread/realtime/stop');
      c.dispose();
    },
  );
  test('audioLevelsFromStats reads the microphone and the remote audio', () {
    StatsReport r(String type, Map<String, dynamic> v) =>
        StatsReport('id', type, 0, v);
    expect(
      audioLevelsFromStats([
        r('media-source', {'kind': 'audio', 'audioLevel': 0.25}),
        r('inbound-rtp', {'kind': 'audio', 'audioLevel': 0.04}),
        r('inbound-rtp', {'kind': 'video', 'audioLevel': 0.9}),
        r('candidate-pair', {'bytesSent': 10}),
      ]),
      (input: 0.25, output: 0.04),
    );
    expect(audioLevelsFromStats([r('transport', {})]), isNull);
  });

  test('a live call polls levels; muting flattens the microphone', () {
    fakeAsync((async) {
      final api = _VoiceApi();
      final media = _Media()..level = (input: 0.25, output: 0);
      final c = VoiceController(
        api: api,
        serviceKey: _service,
        createTransport: () => media,
      );
      c.start('voice');
      async.flushMicrotasks();
      // Nothing is polled before audio flows.
      async.elapse(const Duration(milliseconds: 300));
      expect(c.levels.value.input, 0);
      media.connected();
      async.elapse(const Duration(milliseconds: 600));
      // sqrt(0.25) = 0.5, reached through the attack smoothing.
      expect(c.levels.value.input, closeTo(0.5, 0.01));
      c.toggleMuted();
      async.elapse(const Duration(milliseconds: 200));
      expect(c.levels.value.input, 0);
      c.stop();
      async.flushMicrotasks();
      expect(c.levels.value, (input: 0.0, output: 0.0));
      c.dispose();
      async.flushMicrotasks();
    });
  });

  group('barge-in', () {
    late _VoiceApi api;
    late _Media media;
    late VoiceController c;
    Future<void> say(String role, String delta) async {
      api.event('transcript/delta', {'role': role, 'delta': delta});
      await _tick();
    }

    Future<void> done(String role, String text) async {
      api.event('transcript/done', {'role': role, 'text': text});
      await _tick();
    }

    setUp(() async {
      api = _VoiceApi();
      media = _Media();
      c = VoiceController(
        api: api,
        serviceKey: _service,
        createTransport: () => media,
      );
      await c.start('voice');
      api.event('sdp', {'sdp': 'answer'});
      await _tick();
      expect(c.phase, VoicePhase.active);
    });
    tearDown(() => c.dispose());

    test('talking over a reply cuts its audio until the new reply', () async {
      await say('assistant', 'Here is a long');
      expect(c.turn, VoiceTurn.assistant);
      await say('user', 'wait');
      expect(media.speakerSuppressed, isTrue);
      expect(c.turn, VoiceTurn.user);
      // Stale chunks of the old reply keep arriving: still silent.
      await say('assistant', ' answer about');
      expect(media.speakerSuppressed, isTrue);
      await done('assistant', 'Here is a long answer about');
      expect(c.transcript.last.interrupted, isTrue);
      await done('user', 'wait, use the other file');
      // The reply to what the user just said is heard again.
      await say('assistant', 'Sure, the other file');
      expect(media.speakerSuppressed, isFalse);
      await done('assistant', 'Sure, the other file.');
      expect(c.transcript.last.interrupted, isFalse);
    });

    test(
      'a pause mid-sentence is one utterance, and can interrupt twice',
      () async {
        await say('assistant', 'Starting');
        await say('user', 'hmm');
        await say('user', ' ');
        await say('user', ' actually');
        expect(media.suppressions.where((s) => s).length, 1);
        await done('user', 'hmm actually');
        await done('assistant', 'Starting');
        await say('assistant', 'OK so');
        expect(media.speakerSuppressed, isFalse);
        await say('user', 'wait, one more thing');
        expect(media.speakerSuppressed, isTrue);
        expect(media.suppressions.where((s) => s).length, 2);
      },
    );

    test('speech while muted never interrupts', () async {
      await say('assistant', 'Talking');
      c.toggleMuted();
      await say('user', 'echo');
      expect(media.speakerSuppressed, isFalse);
    });
  });
  testWidgets('a reply that carries on past the interjection is resumed', (
    t,
  ) async {
    final api = _VoiceApi();
    final media = _Media();
    final c = VoiceController(
      api: api,
      serviceKey: _service,
      createTransport: () => media,
    );
    await c.start('voice');
    api.event('sdp', {'sdp': 'answer'});
    await t.pump();
    void say(String role, String delta) =>
        api.event('transcript/delta', {'role': role, 'delta': delta});
    say('assistant', 'Go');
    await t.pump();
    say('user', 'ok');
    await t.pump();
    expect(media.speakerSuppressed, isTrue);
    api.event('transcript/done', {'role': 'user', 'text': 'ok'});
    await t.pump();
    // The server never ended the first reply; it is still talking.
    say('assistant', ' on');
    await t.pump();
    await t.pump(VoiceController.resumeFallback);
    expect(media.speakerSuppressed, isFalse);
    // Dispose clears the floor timers synchronously; the host stop it starts
    // runs on the real zone.
    c.dispose();
    await t.runAsync(_tick);
    await t.pump(VoiceController.speakingTail);
  });
  test('a transient drop reconnects; a lasting one fails visibly', () async {
    final api = _VoiceApi();
    final media = _Media();
    final c = VoiceController(
      api: api,
      serviceKey: _service,
      createTransport: () => media,
    );
    await c.start('voice');
    api.event('sdp', {'sdp': 'answer'});
    await _tick();
    media.interrupted!();
    expect(c.phase, VoicePhase.reconnecting);
    expect(c.busy, isTrue);
    media.connected();
    expect(c.phase, VoicePhase.active);
    media.failure('Audio connection interrupted');
    await _tick();
    await _tick();
    expect(c.phase, VoicePhase.failed);
    expect(c.error, 'Audio connection interrupted');
    expect(media.closed, isTrue);
    c.dispose();
  });
  test(
    'a host close keeps its reason; a hang-up is recorded as such',
    () async {
      final api = _VoiceApi();
      final c = VoiceController(
        api: api,
        serviceKey: _service,
        createTransport: _Media.new,
      );
      await c.start('voice');
      api.event('closed', {'reason': 'session timeout'});
      await _tick();
      await _tick();
      expect(c.phase, VoicePhase.idle);
      expect(c.endedReason, 'session timeout');
      expect(c.endedByUser, isFalse);
      await c.start('voice');
      await c.hangUp();
      expect(c.phase, VoicePhase.idle);
      expect(c.endedByUser, isTrue);
      expect(c.endedReason, isNull);
      c.dispose();
    },
  );
  test(
    'stop releases microphone before an unreachable host acknowledges',
    () async {
      final api = _VoiceApi()..stopAck = Completer<void>();
      final media = _Media();
      final c = VoiceController(
        api: api,
        serviceKey: _service,
        createTransport: () => media,
      );
      await c.start('voice');
      media.connected();
      var settled = false;
      c.addListener(() {
        if (!c.busy) unawaited(c.settled.then((_) => settled = true));
      });
      final stopping = c.hangUp();
      // Ended the moment it is hung up, before anything is awaited.
      expect(c.phase, VoicePhase.idle);
      expect(c.busy, isFalse);
      expect(c.endedByUser, isTrue);
      expect(c.endedAt, isNotNull);
      await _tick();
      expect(media.closed, isTrue);
      expect(settled, isFalse, reason: 'listeners must wait for host cleanup');
      // Talking again at once waits for the host to let the last call go,
      // so that stop cannot land on the new session.
      final again = c.start('voice');
      await _tick();
      expect(api.calls.where((c) => c.$1.endsWith('/start')).length, 1);
      api.stopAck!.complete();
      await stopping;
      await again;
      expect(settled, isTrue);
      expect(api.calls.map((c) => c.$1).toList().sublist(1), [
        'thread/realtime/stop',
        'thread/realtime/start',
      ]);
      expect(c.busy, isTrue);
      c.dispose();
    },
  );
  test('leaving while a redial waits cancels the pending microphone', () async {
    final api = _VoiceApi()..stopAck = Completer<void>();
    var created = 0;
    final c = VoiceController(
      api: api,
      serviceKey: _service,
      createTransport: () {
        created++;
        return _Media();
      },
    );
    await c.start('voice');
    final stopping = c.hangUp();
    final again = c.start('voice');
    final leaving = c.stop();
    api.stopAck!.complete();
    await Future.wait([stopping, again, leaving]);
    expect(created, 1, reason: 'navigation cancels a queued redial');
    expect(c.busy, isFalse);
    expect(api.calls.where((c) => c.$1.endsWith('/start')).length, 1);
    c.dispose();
  });
  test('cancelled microphone startup never starts a remote call', () async {
    final api = _VoiceApi();
    final media = _Media()..pendingOffer = Completer<String>();
    final c = VoiceController(
      api: api,
      serviceKey: _service,
      createTransport: () => media,
    );
    final starting = c.start('voice');
    await c.stop();
    media.pendingOffer!.complete('late-offer');
    await starting;
    expect(media.closed, isTrue);
    expect(api.calls.where((c) => c.$1.endsWith('/start')), isEmpty);
    c.dispose();
  });
  test(
    'late host startup is stopped and cannot overlap a replacement call',
    () async {
      final api = _VoiceApi()..startAck = Completer<void>();
      var created = 0;
      final c = VoiceController(
        api: api,
        serviceKey: _service,
        createTransport: () {
          created++;
          return _Media();
        },
      );
      final starting = c.start('voice');
      await _tick();
      await c.stop();
      await c.start('voice');
      expect(created, 1);
      api.startAck!.complete();
      await starting;
      expect(api.calls.where((c) => c.$1.endsWith('/stop')).length, 2);
      c.dispose();
    },
  );
  test(
    'asynchronous backend rejection is visible and releases media',
    () async {
      final api = _VoiceApi();
      final media = _Media();
      final c = VoiceController(
        api: api,
        serviceKey: _service,
        createTransport: () => media,
      );
      await c.start('voice');
      api.event('error', {'message': 'Account cannot use realtime'});
      await _tick();
      await _tick();
      expect(c.phase, VoicePhase.failed);
      expect(c.error, contains('Account cannot'));
      expect(media.closed, isTrue);
      c.dispose();
    },
  );
  testWidgets('startup deadline releases a pending microphone offer', (
    t,
  ) async {
    final api = _VoiceApi();
    final media = _Media()..pendingOffer = Completer<String>();
    final c = VoiceController(
      api: api,
      serviceKey: _service,
      createTransport: () => media,
    );
    final starting = c.start('voice');
    await t.pump(const Duration(seconds: 45));
    expect(media.closed, isTrue);
    // Broadcast cancellation can return Dart's cached real-zone future.
    await t.runAsync(_tick);
    await t.pump();
    expect(c.phase, VoicePhase.failed);
    media.pendingOffer!.complete('late-offer');
    await t.pump();
    await starting;
    expect(api.calls.where((c) => c.$1.endsWith('/start')), isEmpty);
    c.dispose();
  });
  testWidgets('backgrounding cancels a pending voice thread creation', (
    t,
  ) async {
    AppSessionScreen.debugResetThreadMemory();
    final api = _VoiceApi()..threadAck = Completer<void>();
    var mediaCreated = false;
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          bridgeApiProvider.overrideWithValue(api),
          voiceTransportFactoryProvider.overrideWithValue(() {
            mediaCreated = true;
            return _Media();
          }),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const AppSessionScreen(serviceKey: _service, cwd: '/repo'),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('voice-start')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('voice-start-confirm')));
    await t.pumpAndSettle();
    expect(api.calls.where((c) => c.$1 == 'thread/start'), hasLength(1));
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    api.threadAck!.complete();
    await t.pumpAndSettle();
    expect(mediaCreated, isFalse);
    expect(api.calls.where((c) => c.$1 == 'thread/realtime/start'), isEmpty);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
  });
  for (final (size, dark) in [
    (const Size(390, 844), false),
    (const Size(320, 740), true),
    (const Size(800, 1024), true),
    (const Size(1280, 900), false),
  ]) {
    testWidgets(
      'voice creation, foreground controls and background cleanup $size',
      (t) async {
        AppSessionScreen.debugResetThreadMemory();
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = size;
        addTearDown(t.view.reset);
        final api = _VoiceApi();
        final media = _Media();
        await t.pumpWidget(
          ProviderScope(
            overrides: [
              bridgeApiProvider.overrideWithValue(api),
              voiceTransportFactoryProvider.overrideWithValue(() => media),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: dark ? darkTheme() : lightTheme(),
              home: const AppSessionScreen(serviceKey: _service, cwd: '/repo'),
            ),
          ),
        );
        await t.pumpAndSettle();
        await unfoldComposer(t);
        await t.tap(find.byKey(const Key('voice-start')));
        await t.pumpAndSettle();
        expect(find.text('cove'), findsOneWidget);
        expect(find.text('marin'), findsNothing);
        // The app-server rejects resume/read of a thread whose rollout has
        // not been written yet, which is every freshly started voice thread.
        api.appThreadResumeError = StateError(
          'no rollout found for thread id voice',
        );
        await t.tap(find.byKey(const Key('voice-start-confirm')));
        // The dock's connecting spinner turns until the call is up: pump
        // frames rather than wait for a settle.
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        expect(
          api.calls
              .firstWhere((c) => c.$1 == 'thread/start')
              .$2['threadSource'],
          'pocox-voice',
        );
        expect(api.lastResumed, isNull);
        expect(find.textContaining('no rollout found'), findsNothing);
        // Once the session has spoken, the rollout exists and resume works.
        api.appThreadResumeError = null;
        api.event('sdp', {'sdp': 'answer'});
        // A live call animates its level bars indefinitely; pump frames
        // rather than waiting for a settle that never comes.
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('voice-mute')), findsOneWidget);
        await t.tap(find.byKey(const Key('voice-mute')));
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        expect(media.muted, isTrue);
        expect(t.takeException(), isNull);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await t.pumpAndSettle();
        expect(media.closed, isTrue);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();
      },
    );
  }
  Future<void> mountVoice(
    WidgetTester t,
    _VoiceApi api,
    _Media media,
    AppSessionScreen screen, {
    Size size = const Size(1280, 900),
    bool dark = false,
  }) async {
    AppSessionScreen.debugResetThreadMemory();
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          bridgeApiProvider.overrideWithValue(api),
          voiceTransportFactoryProvider.overrideWithValue(() => media),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: dark ? darkTheme() : lightTheme(),
          builder: (context, child) =>
              RepaintBoundary(key: previewKey, child: child),
          home: screen,
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> answer(
    WidgetTester t,
    _VoiceApi api, {
    String thread = 'voice',
  }) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    api.event('sdp', {'sdp': 'answer'}, thread: thread);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a call docks above the composer, not in a corner, and hangs '
      'up from there', (t) async {
    final api = _VoiceApi();
    final media = _Media();
    await mountVoice(
      t,
      api,
      media,
      const AppSessionScreen(serviceKey: _service, cwd: '/repo', home: true),
    );
    expect(find.byKey(const Key('voice-dock')), findsNothing);
    await t.tap(find.byKey(const Key('voice-start')));
    await t.pumpAndSettle();
    // A conversation not started yet has nothing to join.
    expect(find.byKey(const Key('voice-target-here')), findsNothing);
    expect(find.byKey(const Key('voice-voice-cove')), findsOneWidget);
    await capturePreview(t, 'voice-start-sheet-desktop-light');
    await t.tap(find.byKey(const Key('voice-start-confirm')));
    await answer(t, api);
    final dock = find.byKey(const Key('voice-dock'));
    expect(dock, findsOneWidget);
    expect(
      t.getRect(dock).top,
      greaterThan(900 / 2),
      reason: 'the controls sit at the foot, where the composer is',
    );
    expect(
      t.getRect(dock).height,
      lessThan(96),
      reason: 'one capsule row, not a panel of empty space',
    );
    expect(find.text('Voice conversation'), findsOneWidget);
    expect(find.byKey(const Key('voice-dock-elapsed')), findsOneWidget);
    expect(find.byKey(const Key('voice-mute')), findsOneWidget);
    // The assistant answering: the orb takes up its voice.
    media.level = (input: 0, output: 0.6);
    api.event('transcript/delta', {
      'itemId': 'a1',
      'role': 'assistant',
      'delta': 'The last commit docks the call above the composer.',
    });
    await t.pump(const Duration(milliseconds: 600));
    await t.pump(const Duration(milliseconds: 300));
    await _frames(t);
    await capturePreview(t, 'voice-dock-desktop-light');
    await t.tap(find.byKey(const Key('voice-stop')));
    await t.pump();
    await t.runAsync(_tick);
    await t.pump(const Duration(milliseconds: 300));
    expect(media.closed, isTrue);
    expect(api.calls.last.$1, 'thread/realtime/stop');
    // A voice conversation keeps its dock, ready to talk again, and says
    // how long the call ran.
    expect(find.byKey(const Key('voice-again')), findsOneWidget);
    expect(find.text('Talk again'), findsOneWidget);
    expect(find.byKey(const Key('voice-dock-elapsed')), findsOneWidget);
    await _frames(t);
    await capturePreview(t, 'voice-dock-ended-desktop-light');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 7));
  });

  testWidgets('on a phone the folded composer starts a call without the '
      'keyboard, and the call docks at the foot', (t) async {
    final api = _VoiceApi()
      ..appThreads.add(
        const ThreadMeta(
          id: 'typed',
          preview: 'a typed conversation',
          cwd: '/repo',
          updatedAt: 0,
        ),
      );
    final media = _Media();
    await mountVoice(
      t,
      api,
      media,
      const AppSessionScreen(
        serviceKey: _service,
        threadId: 'typed',
        cwd: '/repo',
      ),
      size: const Size(390, 844),
      dark: true,
    );
    expect(find.byKey(const Key('composer-folded')), findsOneWidget);
    await t.tap(find.byKey(const Key('folded-voice-start')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('voice-start-sheet')), findsOneWidget);
    expect(
      t
          .widget<TextField>(find.byKey(const Key('composer-input')))
          .focusNode!
          .hasFocus,
      isFalse,
      reason: 'talking needs no keyboard',
    );
    await capturePreview(t, 'voice-start-sheet-phone-dark');
    await t.tap(find.byKey(const Key('voice-start-confirm')));
    await answer(t, api, thread: 'typed');
    final dock = find.byKey(const Key('voice-dock'));
    expect(dock, findsOneWidget);
    expect(t.getRect(dock).bottom, greaterThan(844 * 0.75));
    expect(t.getRect(dock).height, lessThan(96));
    final hangUp = t.getRect(find.byKey(const Key('voice-stop')));
    expect(hangUp.shortestSide, greaterThanOrEqualTo(48));
    media.level = (input: 0.5, output: 0);
    api.event('transcript/delta', {
      'itemId': 'u1',
      'role': 'user',
      'delta': 'What changed in the last commit, and is it safe to ship?',
    }, thread: 'typed');
    await t.pump(const Duration(milliseconds: 600));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('voice-dock-caption')), findsOneWidget);
    await _frames(t);
    await capturePreview(t, 'voice-dock-phone-dark');
    // Muted: the call goes quiet grey, the microphone says why in red.
    await t.tap(find.byKey(const Key('voice-mute')));
    await _frames(t);
    expect(media.muted, isTrue);
    expect(find.text('Microphone muted'), findsOneWidget);
    await capturePreview(t, 'voice-dock-muted-phone-dark');
    await t.tap(find.byKey(const Key('voice-stop')));
    // Ended at once, on the phone's narrow row too.
    await t.pump();
    expect(find.byKey(const Key('voice-again')), findsOneWidget);
    expect(find.byKey(const Key('voice-dock-dismiss')), findsOneWidget);
    await t.runAsync(_tick);
    await _frames(t);
    await capturePreview(t, 'voice-dock-ended-phone-dark');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 7));
  });

  testWidgets('a call joins the typed conversation on screen, or gets one '
      'of its own', (t) async {
    final api = _VoiceApi()
      ..appThreads.add(
        const ThreadMeta(
          id: 'typed',
          preview: 'a typed conversation',
          cwd: '/repo',
          updatedAt: 0,
        ),
      );
    final media = _Media();
    await mountVoice(
      t,
      api,
      media,
      const AppSessionScreen(
        serviceKey: _service,
        threadId: 'typed',
        cwd: '/repo',
      ),
    );
    await t.tap(find.byKey(const Key('voice-start')));
    await t.pumpAndSettle();
    // Both places, this conversation first.
    expect(find.byKey(const Key('voice-target-here')), findsOneWidget);
    expect(find.byKey(const Key('voice-target-new')), findsOneWidget);
    await t.tap(find.byKey(const Key('voice-start-confirm')));
    await answer(t, api, thread: 'typed');
    expect(api.calls.map((c) => c.$1), isNot(contains('thread/start')));
    expect(
      api.calls
          .firstWhere((c) => c.$1 == 'thread/realtime/start')
          .$2['threadId'],
      'typed',
      reason: 'the call starts on the typed thread, which gives it context',
    );
    expect(find.text('Voice · this conversation'), findsOneWidget);
    expect(find.byKey(const Key('voice-mute')), findsOneWidget, reason: 'live');
    await t.tap(find.byKey(const Key('voice-stop')));
    await t.pump();
    await t.runAsync(_tick);
    await t.pump(const Duration(milliseconds: 300));
    expect(media.closed, isTrue);

    // The other choice makes a voice conversation of its own.
    api.calls.clear();
    await t.tap(find.byKey(const Key('voice-start')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('voice-target-new')));
    await t.pump();
    await t.tap(find.byKey(const Key('voice-start-confirm')));
    await answer(t, api);
    expect(
      api.calls.firstWhere((c) => c.$1 == 'thread/start').$2['threadSource'],
      'pocox-voice',
    );
    expect(
      api.calls
          .firstWhere((c) => c.$1 == 'thread/realtime/start')
          .$2['threadId'],
      'voice',
    );
    expect(find.text('Voice conversation'), findsOneWidget);
    await t.tap(find.byKey(const Key('voice-stop')));
    await t.pump();
    await t.runAsync(_tick);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 7));
  });

  testWidgets('opening another conversation ends the call and its capture', (
    t,
  ) async {
    AppSessionScreen.debugResetThreadMemory();
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1280, 900);
    addTearDown(t.view.reset);
    final api = _VoiceApi();
    api.appThreads.add(
      const ThreadMeta(
        id: 'other',
        preview: 'another conversation',
        cwd: '/repo',
        updatedAt: 0,
      ),
    );
    final media = _Media();
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          bridgeApiProvider.overrideWithValue(api),
          voiceTransportFactoryProvider.overrideWithValue(() => media),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: lightTheme(),
          home: const AppSessionScreen(
            serviceKey: _service,
            cwd: '/repo',
            home: true,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('voice-start')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('voice-start-confirm')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    api.event('sdp', {'sdp': 'answer'});
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(media.closed, isFalse);
    await t.tap(find.text('another conversation'));
    await t.pump();
    await t.runAsync(_tick);
    await t.pump(const Duration(milliseconds: 300));
    expect(media.closed, isTrue);
    expect(api.calls.map((c) => c.$1), contains('thread/realtime/stop'));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 7));
  });
  testWidgets('voice history restores canonical spoken segments', (t) async {
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: VoiceHistoryDialog(
          api: _VoiceApi(),
          serviceKey: _service,
          threadId: 'voice',
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Saved spoken request'), findsOneWidget);
  });
}
