part of '../acp_supplement_test.dart';

const acp = 'pcx:dev:acp:claude';

AppCapabilities caps({
  required bool steer,
  int generation = 1,
  bool imageInput = false,
}) => negotiatedAcpCapabilities(
  providerName: 'Claude',
  generation: generation,
  imageInput: imageInput,
  steer: steer,
);

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Open session `ses-1` with turn `t1` running.
Future<FakeBridgeApi> running(
  WidgetTester t, {
  bool steer = true,
  bool imageInput = false,
  List<ThreadMeta> threads = const [],
}) async {
  final api = FakeBridgeApi()
    ..acpCapabilities[acp] = caps(steer: steer, imageInput: imageInput)
    ..autoCompleteTurn = false;
  api.appThreads.addAll(threads);
  await api.appConnect(acp, 28080);
  await t.pumpWidget(
    host(const AppSessionScreen(serviceKey: acp, threadId: 'ses-1'), api),
  );
  await frames(t);
  api.pushEvent(
    acp,
    const AppEvent(
      kind: 'turn/started',
      threadId: 'ses-1',
      raw: '{"turnId":"t1"}',
    ),
  );
  await frames(t);
  return api;
}

void ended(FakeBridgeApi api, String turn) => api.pushEvent(
  acp,
  AppEvent(
    kind: 'turn/completed',
    threadId: 'ses-1',
    raw: '{"turnId":"$turn"}',
  ),
);

String composerText(WidgetTester t) => t
    .widget<TextField>(find.byKey(const Key('composer-input')))
    .controller!
    .text;

/// Type [text] with Supplement selected and press Send.
Future<void> supplement(WidgetTester t, String text) async {
  await t.tap(find.byKey(const Key('supplement-toggle')));
  await t.pump();
  await t.enterText(find.byKey(const Key('composer-input')), text);
  await t.pump();
  await t.tap(find.byKey(const Key('send-btn')));
  await frames(t);
}

/// Pick [names] as images through the `+` menu while a turn runs.
Future<void> attachImages(
  WidgetTester t,
  FakeImagePicker picker,
  List<String> names,
) async {
  picker.files = [for (final name in names) MemXFile(tinyPng(), name)];
  await t.tap(find.byKey(const Key('attach-menu-btn')));
  await frames(t);
  await t.tap(find.byKey(const Key('attach-btn')));
  await frames(t);
}

/// Replace the host behind [acp] with generation 2 while a request waits.
Future<void> replaceHost(
  WidgetTester t,
  FakeBridgeApi api, {
  bool imageInput = false,
}) async {
  api.acpCapabilities[acp] = caps(
    steer: true,
    generation: 2,
    imageInput: imageInput,
  );
  api.pushEvent(
    acp,
    const AppEvent(kind: 'acp/host/state', raw: '{"generation":2}'),
  );
  await frames(t);
}

const twoSessions = [
  ThreadMeta(id: 'ses-1', preview: 'one', cwd: '/work', updatedAt: 2),
  ThreadMeta(id: 'ses-2', preview: 'two', cwd: '/work', updatedAt: 1),
];

/// The notice an answer that no longer owns its input shows.
Finder staleNotice() => find.textContaining('回复到达时');
