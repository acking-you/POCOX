// What a native OpenCode turn shows when the model fails or returns its
// output only as reasoning: a light failure card (never a reply, never also
// the error banner) with a Retry only for the current failure, which re-sends
// the failed message with the model chosen since and leaves the draft alone;
// a stop shows once; reasoning-only output is shown in full and said to be
// reasoning, while ordinary reasoning stays folded.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/opencode_chat.dart';

const _svc = openCodeService;
const _thread = 'ses_fail';
const _ask = 'Summarize the build log.';
const _region =
    "This model isn't available in your region. "
    'Choose another model, then retry.';

/// A host-classified failure of the message answering [prompt].
String _failureOf({String item = '#error:msg_1a', String prompt = 'msg_1'}) =>
    '{"code":"region_unavailable","statusCode":403,"retryable":false,'
    '"model":"muse-spark-1.3-contributor-free","provider":"opencode",'
    '"itemId":"$item","turnId":"$prompt"}';
final _failure = _failureOf();
const _bannerFallback =
    'This model is unavailable in your region. '
    'Choose another model.';

ThreadItem _item(String id, String turn, String type, String text) =>
    ThreadItem(id: id, turnId: turn, itemType: type, title: '', text: text);

AppEvent _event(
  String kind,
  String turn, {
  String? id,
  String? type,
  String? text,
  String? raw,
}) => AppEvent(
  kind: kind,
  threadId: _thread,
  itemId: id,
  itemType: type,
  text: text,
  raw: raw ?? '{"turnId":"$turn","turn":{"id":"$turn"}}',
);

/// The terminal event of running [turn], failed with the classified error
/// of the message [item] answering [prompt] (a supplement's own prompt).
AppEvent _failed(
  String turn, {
  String item = '#error:msg_1a',
  String? prompt,
}) => _event(
  'turn/completed',
  turn,
  raw:
      '{"threadId":"$_thread","turn":{"id":"$turn","status":"failed",'
      '"error":{"message":"$_bannerFallback","code":"region_unavailable",'
      '"statusCode":403,"retryable":false,'
      '"model":"muse-spark-1.3-contributor-free","provider":"opencode",'
      '"itemId":"$item","turnId":"${prompt ?? turn}"}}}',
);

AppEvent _completed(String turn, {String status = 'completed'}) => _event(
  'turn/completed',
  turn,
  raw: '{"threadId":"$_thread","turn":{"id":"$turn","status":"$status"}}',
);

const _settings = SessionSettings(
  configOptions: [
    SessionConfigOption(
      id: 'model',
      name: 'Model',
      category: 'model',
      currentValue: 'opencode/muse-spark-1.3-contributor-free',
      values: [
        SessionConfigValue(
          value: 'opencode/muse-spark-1.3-contributor-free',
          name: 'Muse Spark',
        ),
        SessionConfigValue(
          value: 'opencode/mimo-v2.6-flash-free',
          name: 'Mimo',
        ),
      ],
    ),
  ],
);

Future<FakeBridgeApi> _open(
  WidgetTester t, {
  List<ThreadItem> items = const [],
  SessionAccess? access,
  Size? size,
  List<ThreadMeta> others = const [],
}) {
  final api = FakeBridgeApi()
    ..acpCapabilities[_svc] = negotiatedOpenCodeCapabilities(generation: 7)
    ..metadataOnlyFollow = true
    ..announceTurnStart = false
    ..appThreads.add(
      const ThreadMeta(
        id: _thread,
        preview: 'p',
        cwd: '/project',
        updatedAt: 2,
      ),
    )
    ..appThreads.addAll(others)
    ..readResult = ThreadHistory(
      running: false,
      cwd: '/project',
      items: [
        _item('msg_0', 'msg_0', 'userMessage', 'hello'),
        _item('msg_0a', 'msg_0', 'agentMessage', 'hi there'),
        ...items,
      ],
    );
  api.sessionOpenResults.add(
    access ?? openCodeWritable(_thread, generation: 7),
  );
  api.sessionSettings['$_svc|$_thread'] = _settings;
  return mountChat(
    t,
    api,
    threadId: _thread,
    cwd: '/project',
    size: size ?? const Size(1280, 900),
  );
}

/// Send [text] from the composer and let the host announce [turn].
Future<void> _sendTurn(
  WidgetTester t,
  FakeBridgeApi api,
  String text,
  String turn,
) async {
  await typeMessage(t, text);
  await tapSend(t);
  api.pushEvent(_svc, _event('turn/started', turn));
  await frames(t);
}

Finder _card() => find.byKey(const Key('model-error-card'));
Finder _retry() => find.byKey(const Key('model-error-retry'));
Finder _shown(String text) => find.text(text, findRichText: true);

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('a model failure is one card with its reason and model; Retry '
      'sends the failed message with the newly chosen model and keeps the '
      'draft', (t) async {
    final api = await _open(t);
    await _sendTurn(t, api, _ask, 'msg_1');
    api
      ..pushEvent(
        _svc,
        _event(
          'item/completed',
          'msg_1',
          id: '#error:msg_1a',
          type: 'modelError',
          text: _failure,
        ),
      )
      ..pushEvent(_svc, _failed('msg_1'));
    await frames(t);

    expect(_card(), findsOneWidget);
    expect(_shown(_region), findsOneWidget);
    expect(
      _shown('Model: opencode/muse-spark-1.3-contributor-free · HTTP 403'),
      findsOneWidget,
    );
    // Neither a reply nor the error banner says it again.
    expect(find.textContaining(_bannerFallback), findsNothing);
    expect(find.textContaining('APIError'), findsNothing);
    expect(_retry(), findsOneWidget);

    // The model can still be changed, and a new draft is being written.
    await pickOption(t, 'model', 'opencode/mimo-v2.6-flash-free');
    expect(api.sessionConfigCalls, [
      (_thread, 'model', 'opencode/mimo-v2.6-flash-free'),
    ]);
    await typeMessage(t, 'unsent next question');

    await t.tap(_retry());
    await frames(t);
    expect(api.turnStartCount, 2);
    expect(api.lastTurnThread, _thread);
    expect(api.lastTurnText, _ask);
    // OpenCode's model is the session option chosen above, not a turn field.
    expectNoModelMenuSettings(api);
    expect(composerText(t), 'unsent next question');
    // The retried message is shown as the new turn's message; while it runs
    // the old failure offers nothing.
    expect(_shown(_ask), findsNWidgets(2));
    expect(_retry(), findsNothing);

    api
      ..pushEvent(_svc, _event('turn/started', 'msg_2'))
      ..pushEvent(
        _svc,
        _event(
          'item/completed',
          'msg_2',
          id: 'msg_2a',
          type: 'agentMessage',
          text: 'Build passed.',
        ),
      )
      ..pushEvent(_svc, _completed('msg_2'));
    await frames(t);
    expect(_shown('Build passed.'), findsOneWidget);
    // The answered failure stays in the history, without an action.
    expect(_card(), findsOneWidget);
    expect(_retry(), findsNothing);
    expect(api.turnStartCount, 2);
    expect(composerText(t), 'unsent next question');
    expect(t.takeException(), isNull);
  });

  testWidgets('a failure reported only by the turn end shows its card once, '
      'also when the host item follows', (t) async {
    final api = await _open(t);
    await _sendTurn(t, api, _ask, 'msg_1');
    api.pushEvent(_svc, _failed('msg_1'));
    await frames(t);
    expect(_card(), findsOneWidget);
    expect(_shown(_region), findsOneWidget);
    expect(find.textContaining(_bannerFallback), findsNothing);

    api.pushEvent(
      _svc,
      _event(
        'item/completed',
        'msg_1',
        id: '#error:msg_1a',
        type: 'modelError',
        text: _failure,
      ),
    );
    await frames(t);
    expect(_card(), findsOneWidget);
    expect(_retry(), findsOneWidget);
  });

  testWidgets('a failure pauses the queue; Retry resends the failed message '
      'first and the queue continues after it', (t) async {
    final api = await _open(t);
    await _sendTurn(t, api, _ask, 'msg_1');
    await typeMessage(t, 'queued follow-up');
    await tapSend(t);
    expect(find.byKey(const Key('queued-0')), findsOneWidget);

    api.pushEvent(_svc, _failed('msg_1'));
    await frames(t);
    // Nothing is sent into the known failure.
    expect(api.turnStartCount, 1);
    expect(find.byKey(const Key('queued-0')), findsOneWidget);
    expect(find.textContaining('Paused.'), findsOneWidget);

    await t.tap(_retry());
    await frames(t);
    expect(api.turnStartCount, 2);
    expect(api.lastTurnText, _ask);
    api
      ..pushEvent(_svc, _event('turn/started', 'msg_2'))
      ..pushEvent(_svc, _completed('msg_2'));
    await frames(t);
    expect(api.turnStartCount, 3);
    expect(api.lastTurnText, 'queued follow-up');
    expect(find.byKey(const Key('queued-0')), findsNothing);
  });

  testWidgets('a stop shows once, without a failure card or banner', (t) async {
    final api = await _open(t);
    await _sendTurn(t, api, _ask, 'msg_1');
    api.pushEvent(
      _svc,
      _event(
        'item/completed',
        'msg_1',
        id: 'msg_1r',
        type: 'reasoning',
        text: 'thinking',
      ),
    );
    await frames(t);
    await t.tap(find.byKey(const Key('stop-btn')));
    await frames(t);
    // The local marker comes first; the host's own stop item replaces it.
    api.pushEvent(_svc, _completed('msg_1', status: 'interrupted'));
    await frames(t);
    expect(_shown('Stopped'), findsOneWidget);
    api.pushEvent(
      _svc,
      _event(
        'item/completed',
        'msg_1',
        id: '#error:msg_1a',
        type: 'interrupted',
        text: '',
      ),
    );
    await frames(t);
    expect(_shown('Stopped'), findsOneWidget);
    expect(_card(), findsNothing);
    expect(find.byKey(const Key('session-error-dismiss')), findsNothing);
  });

  testWidgets('history shows what happened: an answered failure and full '
      'reasoning-only output, with Retry only for a current failure', (
    t,
  ) async {
    const output = '最终答案:构建通过,共 3 个警告。\n\n- 第一条\n- 第二条';
    await _open(
      t,
      items: [
        _item('msg_1', 'msg_1', 'userMessage', _ask),
        _item('#error:msg_1a', 'msg_1', 'modelError', _failure),
        _item('msg_2', 'msg_2', 'userMessage', 'Try again'),
        _item('msg_2r', 'msg_2', 'reasoningOutput', output),
      ],
    );
    expect(_card(), findsOneWidget);
    expect(_shown(_region), findsOneWidget);
    expect(_retry(), findsNothing, reason: 'a later turn answered it');
    expect(find.byKey(const Key('reasoning-output')), findsOneWidget);
    expect(
      _shown(
        'The model returned this as reasoning, without a separate answer.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('最终答案:构建通过', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('第二条', findRichText: true), findsOneWidget);
  });

  testWidgets('a reopened conversation whose last turn failed offers Retry; '
      'a followed one does not', (t) async {
    final failedLast = [
      _item('msg_1', 'msg_1', 'userMessage', _ask),
      _item('#error:msg_1a', 'msg_1', 'modelError', _failure),
    ];
    final api = await _open(t, items: failedLast);
    expect(_retry(), findsOneWidget);
    await t.tap(_retry());
    await frames(t);
    expect(api.turnStartCount, 1);
    expect(api.lastTurnText, _ask);

    await t.pumpWidget(const SizedBox.shrink());
    await frames(t);
    AppSessionScreen.debugResetThreadMemory();
    await _open(
      t,
      items: failedLast,
      access: const SessionAccess(
        sessionId: _thread,
        hostId: 'host-1',
        generation: 7,
        provider: 'opencode',
        mode: 'follow',
        writer: 'native_client',
        turn: 'idle',
        exclusion: '',
        reason: 'external_idle',
        canRelease: false,
        recheck: true,
      ),
    );
    expect(_card(), findsOneWidget);
    expect(_retry(), findsNothing);
  });

  testWidgets('streamed reasoning that completes as the only output is shown '
      'in full; ordinary reasoning before an answer stays folded', (t) async {
    final api = await _open(t);
    await _sendTurn(t, api, _ask, 'msg_1');
    api.pushEvent(
      _svc,
      _event(
        'item/reasoning/delta',
        'msg_1',
        id: 'msg_1r',
        type: 'reasoning',
        text: 'Final: the build',
      ),
    );
    await frames(t);
    expect(find.byKey(const Key('reasoning-output')), findsNothing);
    api
      ..pushEvent(
        _svc,
        _event(
          'item/completed',
          'msg_1',
          id: 'msg_1r',
          type: 'reasoningOutput',
          text: 'Final: the build passed with 3 warnings.',
        ),
      )
      ..pushEvent(_svc, _completed('msg_1'));
    await frames(t);
    expect(find.byKey(const Key('reasoning-output')), findsOneWidget);
    expect(
      find.textContaining(
        'the build passed with 3 warnings',
        findRichText: true,
      ),
      findsOneWidget,
    );

    await _sendTurn(t, api, 'And now?', 'msg_2');
    api
      ..pushEvent(
        _svc,
        _event(
          'item/completed',
          'msg_2',
          id: 'msg_2r',
          type: 'reasoning',
          text: 'private chain of thought',
        ),
      )
      ..pushEvent(
        _svc,
        _event(
          'item/completed',
          'msg_2',
          id: 'msg_2a',
          type: 'agentMessage',
          text: 'Nothing else to do.',
        ),
      )
      ..pushEvent(_svc, _completed('msg_2'));
    await frames(t);
    expect(_shown('Nothing else to do.'), findsOneWidget);
    expect(find.byKey(const Key('reasoning-output')), findsOneWidget);
    expect(
      find.textContaining('private chain of thought', findRichText: true),
      findsNothing,
    );
  });

  group('change model', () {
    Future<FakeBridgeApi> failed(WidgetTester t, {Size? size}) async {
      final api = await _open(
        t,
        items: [
          _item('msg_1', 'msg_1', 'userMessage', _ask),
          _item('#error:msg_1a', 'msg_1', 'modelError', _failure),
        ],
        size: size,
      );
      await typeMessage(t, 'my draft');
      return api;
    }

    Future<void> chooseMimo(WidgetTester t) async {
      await t.tap(find.byKey(const Key('model-error-change-model')));
      await t.pumpAndSettle();
      await t.tap(optionChoice('opencode/mimo-v2.6-flash-free'));
      await frames(t, 4);
    }

    ButtonStyleButton retryButton(WidgetTester t) =>
        t.widget<ButtonStyleButton>(_retry());

    testWidgets('the card opens the model list; choosing sends nothing', (
      t,
    ) async {
      final api = await failed(t);
      await chooseMimo(t);
      expect(api.sessionConfigCalls, [
        (_thread, 'model', 'opencode/mimo-v2.6-flash-free'),
      ]);
      expect(api.turnStartCount, 0);
      expect(composerText(t), 'my draft');
      expect(retryButton(t).onPressed, isNotNull);
    });

    testWidgets('Retry waits while the model change is saved', (t) async {
      final api = await failed(t);
      final gate = api.sessionConfigGate = Completer<void>();
      await chooseMimo(t);
      // Still saving: a Retry now would run with the old model.
      expect(retryButton(t).onPressed, isNull);
      await t.tap(_retry(), warnIfMissed: false);
      await frames(t);
      expect(api.turnStartCount, 0);

      gate.complete();
      await frames(t);
      expect(retryButton(t).onPressed, isNotNull);
      await t.tap(_retry());
      await frames(t);
      expect(api.turnStartCount, 1);
      expect(api.lastTurnText, _ask);
      expect(composerText(t), 'my draft');
    });

    testWidgets('a refused change says so and keeps the model and draft', (
      t,
    ) async {
      final api = await failed(t);
      api.sessionConfigError = StateError('model refused');
      await chooseMimo(t);
      expect(
        find.textContaining("Couldn't switch the model", findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('model refused'), findsOneWidget);
      expect(optionShows('model', 'Muse Spark'), findsOneWidget);
      expect(composerText(t), 'my draft');
      expect(api.turnStartCount, 0);
      expect(retryButton(t).onPressed, isNotNull);
    });

    testWidgets('on a phone both actions fit below the reason', (t) async {
      await failed(t, size: const Size(390, 844));
      expect(find.byKey(const Key('model-error-change-model')), findsOneWidget);
      expect(_retry(), findsOneWidget);
      final card = t.getRect(_card());
      expect(card.right, lessThanOrEqualTo(390));
      expect(t.getRect(_retry()).bottom, lessThanOrEqualTo(card.bottom));
      expect(t.takeException(), isNull);
    });
  });

  testWidgets('an incomplete failed message is not resent as recorded', (
    t,
  ) async {
    for (final evidence in [
      [_item('#input:msg_1', 'msg_1', 'contentOmitted', 'input')],
      [_item('#attachments:msg_1', 'msg_1', 'contentOmitted', 'attachments')],
    ]) {
      AppSessionScreen.debugResetThreadMemory();
      final api = await _open(
        t,
        items: [
          _item('msg_1', 'msg_1', 'userMessage', 'Summarize the bu'),
          ...evidence,
          _item('#error:msg_1a', 'msg_1', 'modelError', _failure),
        ],
      );
      expect(_card(), findsOneWidget);
      expect(_retry(), findsNothing);
      expect(find.byKey(const Key('model-error-incomplete')), findsOneWidget);
      expect(find.byKey(const Key('model-error-change-model')), findsOneWidget);
      expect(api.turnStartCount, 0);
      await t.pumpWidget(const SizedBox.shrink());
      await frames(t);
    }
  });

  testWidgets('a host-path image is not resent as inline data', (t) async {
    await _open(
      t,
      items: [
        const ThreadItem(
          id: 'msg_1',
          turnId: 'msg_1',
          itemType: 'userMessage',
          title: '',
          text: _ask,
          images: ['/tmp/shot.png'],
        ),
        _item('#error:msg_1a', 'msg_1', 'modelError', _failure),
      ],
    );
    expect(_retry(), findsNothing);
    expect(find.byKey(const Key('model-error-incomplete')), findsOneWidget);
  });

  testWidgets('a terminal-only card is replaced by the host item from a '
      'history read, read again or not', (t) async {
    final api = await _open(t);
    await _sendTurn(t, api, _ask, 'msg_1');
    api.pushEvent(_svc, _failed('msg_1'));
    await frames(t);
    expect(_card(), findsOneWidget);

    api.readResult = ThreadHistory(
      running: false,
      cwd: '/project',
      items: [
        _item('msg_0', 'msg_0', 'userMessage', 'hello'),
        _item('msg_0a', 'msg_0', 'agentMessage', 'hi there'),
        _item('msg_1', 'msg_1', 'userMessage', _ask),
        _item('#error:msg_1a', 'msg_1', 'modelError', _failure),
      ],
    );
    for (var read = 0; read < 2; read++) {
      api.pushEvent(_svc, _event('thread/compacted', 'msg_1'));
      await frames(t, 20);
      expect(_card(), findsOneWidget);
      expect(_shown(_ask), findsOneWidget);
    }
    expect(_retry(), findsOneWidget);
  });

  testWidgets('a local stop marker gives way to the host stop from a '
      'history read', (t) async {
    final api = await _open(t);
    await _sendTurn(t, api, _ask, 'msg_1');
    api.pushEvent(
      _svc,
      _event('item/completed', 'msg_1', id: 'r', type: 'reasoning', text: 'x'),
    );
    await frames(t);
    await t.tap(find.byKey(const Key('stop-btn')));
    await frames(t);
    api.pushEvent(_svc, _completed('msg_1', status: 'interrupted'));
    await frames(t);
    expect(_shown('Stopped'), findsOneWidget);

    api.readResult = ThreadHistory(
      running: false,
      cwd: '/project',
      items: [
        _item('msg_1', 'msg_1', 'userMessage', _ask),
        _item('#error:msg_1a', 'msg_1', 'interrupted', ''),
      ],
    );
    for (var read = 0; read < 2; read++) {
      api.pushEvent(_svc, _event('thread/compacted', 'msg_1'));
      await frames(t, 20);
      expect(_shown('Stopped'), findsOneWidget);
    }
  });

  testWidgets('a failed supplement is identified by its own prompt: the '
      'running prompt is never resent in its place', (t) async {
    final api = await _open(t);
    await _sendTurn(t, api, _ask, 'msg_1');
    // The supplement's reply failed; the running turn ends with it.
    api.pushEvent(
      _svc,
      _failed('msg_1', item: '#error:msg_1sa', prompt: 'msg_1s'),
    );
    await frames(t);
    expect(_card(), findsOneWidget);
    expect(_retry(), findsNothing);
    expect(find.byKey(const Key('model-error-incomplete')), findsOneWidget);

    // The host item arrives late, under the supplement's prompt.
    api.pushEvent(
      _svc,
      _event(
        'item/completed',
        'msg_1s',
        id: '#error:msg_1sa',
        type: 'modelError',
        text: _failureOf(item: '#error:msg_1sa', prompt: 'msg_1s'),
      ),
    );
    await frames(t);
    expect(_card(), findsOneWidget);
    expect(_retry(), findsNothing);

    // History holds the supplement itself: that is what Retry sends.
    api.readResult = ThreadHistory(
      running: false,
      cwd: '/project',
      items: [
        _item('msg_1', 'msg_1', 'userMessage', _ask),
        _item('msg_1a', 'msg_1', 'agentMessage', 'Working on it'),
        _item('msg_1s', 'msg_1s', 'userMessage', 'Also list warnings.'),
        _item(
          '#error:msg_1sa',
          'msg_1s',
          'modelError',
          _failureOf(item: '#error:msg_1sa', prompt: 'msg_1s'),
        ),
      ],
    );
    api.pushEvent(_svc, _event('thread/compacted', 'msg_1'));
    await frames(t, 20);
    expect(_card(), findsOneWidget);
    await t.tap(_retry());
    await frames(t);
    expect(api.turnStartCount, 2);
    expect(api.lastTurnText, 'Also list warnings.');
  });

  group('while a model change is saved', () {
    const other = 'ses_other';

    Future<FakeBridgeApi> failedWithDraft(WidgetTester t) async {
      final api = await _open(
        t,
        items: [
          _item('msg_1', 'msg_1', 'userMessage', _ask),
          _item('#error:msg_1a', 'msg_1', 'modelError', _failure),
        ],
        others: const [
          ThreadMeta(
            id: other,
            preview: 'other',
            cwd: '/project',
            updatedAt: 1,
          ),
        ],
      );
      api.sessionSettings['$_svc|$other'] = _settings;
      await typeMessage(t, 'my draft');
      return api;
    }

    Future<void> chooseFromCard(WidgetTester t) async {
      await t.tap(find.byKey(const Key('model-error-change-model')));
      await t.pumpAndSettle();
      await t.tap(optionChoice('opencode/mimo-v2.6-flash-free'));
      await frames(t, 4);
    }

    bool sendEnabled(WidgetTester t) =>
        t.widget<IconButton>(find.byKey(const Key('send-btn'))).onPressed !=
        null;

    testWidgets('no send, Enter or second choice goes out; afterwards '
        'nothing is sent by itself', (t) async {
      // Enter sends from the desktop composer.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final api = await failedWithDraft(t);
        final gate = api.sessionConfigGate = Completer<void>();
        await chooseFromCard(t);
        expect(sendEnabled(t), isFalse);
        await t.showKeyboard(find.byKey(const Key('composer-input')));
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await frames(t);
        await t.tap(find.byKey(const Key('send-btn')), warnIfMissed: false);
        await frames(t);
        // The session's own option waits too: no second save starts.
        await t.tap(
          find.byKey(const Key('agent-config-model')),
          warnIfMissed: false,
        );
        await frames(t);
        expect(api.sessionConfigCalls, hasLength(1));
        expect(api.turnStartCount, 0);
        expect(composerText(t), contains('my draft'));
        expect(find.byKey(const Key('queued-0')), findsNothing);

        gate.complete();
        await frames(t);
        expect(api.turnStartCount, 0, reason: 'only usable again');
        expect(sendEnabled(t), isTrue);
        await tapSend(t);
        expect(api.turnStartCount, 1);
        expect(api.lastTurnText, contains('my draft'));
        await t.pumpWidget(const SizedBox.shrink());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a refused change releases the composer with its draft', (
      t,
    ) async {
      final api = await failedWithDraft(t);
      final gate = api.sessionConfigGate = Completer<void>();
      await chooseFromCard(t);
      expect(sendEnabled(t), isFalse);
      api.sessionConfigError = StateError('model refused');
      gate.complete();
      await frames(t);
      expect(
        find.textContaining("Couldn't switch the model", findRichText: true),
        findsOneWidget,
      );
      expect(composerText(t), 'my draft');
      expect(sendEnabled(t), isTrue);
      expect(api.turnStartCount, 0);
    });

    testWidgets("an earlier conversation's save neither holds nor releases "
        'the one shown now', (t) async {
      final api = await failedWithDraft(t);
      final first = api.sessionConfigGate = Completer<void>();
      await chooseFromCard(t);
      api.sessionOpenResults.add(openCodeWritable(other, generation: 7));
      await t.tap(find.byKey(const Key('conv-tile-$other')));
      await frames(t, 20);
      // Not held by the other conversation's save.
      await typeMessage(t, 'here');
      expect(sendEnabled(t), isTrue);

      final second = api.sessionConfigGate = Completer<void>();
      // Chosen from the composer; its progress keeps animating while held.
      await t.tap(find.byKey(const Key('agent-config-model')));
      await t.pumpAndSettle();
      await t.tap(optionChoice('opencode/mimo-v2.6-flash-free'));
      await frames(t, 4);
      expect(api.sessionConfigCalls.last.$1, other);
      expect(sendEnabled(t), isFalse);

      // The earlier save ends (refused): nothing is said or released here.
      api.sessionConfigError = StateError('model refused');
      first.complete();
      await frames(t);
      expect(find.textContaining("Couldn't switch the model"), findsNothing);
      expect(sendEnabled(t), isFalse);

      second.complete();
      await frames(t);
      expect(sendEnabled(t), isTrue);
      expect(api.turnStartCount, 0);
    });
  });

  group('a stop the host names', () {
    const outer = 'msg_1';
    const stopRow = '#error:msg_1sa';
    // The stopped reply answered a supplement inside the running turn.
    final stopped = _event(
      'turn/completed',
      outer,
      raw:
          '{"threadId":"$_thread","turn":{"id":"$outer",'
          '"status":"interrupted","error":null,'
          '"interruption":{"itemId":"$stopRow","turnId":"msg_1s"}}}',
    );
    final row = _event(
      'item/completed',
      'msg_1s',
      id: stopRow,
      type: 'interrupted',
      text: '',
    );
    final history = ThreadHistory(
      running: false,
      cwd: '/project',
      items: [
        _item('msg_1', 'msg_1', 'userMessage', _ask),
        _item('msg_1s', 'msg_1s', 'userMessage', 'Also list warnings.'),
        _item(stopRow, 'msg_1s', 'interrupted', ''),
      ],
    );

    Future<void> rereadTwice(WidgetTester t, FakeBridgeApi api) async {
      api.readResult = history;
      for (var read = 0; read < 2; read++) {
        api.pushEvent(_svc, _event('thread/compacted', outer));
        await frames(t, 20);
        expect(_shown('Stopped'), findsOneWidget);
      }
    }

    testWidgets('end first, then its row and history: one stop, '
        'without pressing Stop here', (t) async {
      final api = await _open(t);
      await _sendTurn(t, api, _ask, outer);
      api.pushEvent(_svc, stopped);
      await frames(t);
      expect(_shown('Stopped'), findsOneWidget);
      expect(_card(), findsNothing);
      api.pushEvent(_svc, row);
      await frames(t);
      expect(_shown('Stopped'), findsOneWidget);
      await rereadTwice(t, api);
    });

    testWidgets('row first, then the end and history: one stop', (t) async {
      final api = await _open(t);
      await _sendTurn(t, api, _ask, outer);
      await t.tap(find.byKey(const Key('stop-btn')));
      await frames(t);
      api.pushEvent(_svc, row);
      await frames(t);
      api.pushEvent(_svc, stopped);
      await frames(t);
      expect(_shown('Stopped'), findsOneWidget);
      await rereadTwice(t, api);
    });
  });
}
