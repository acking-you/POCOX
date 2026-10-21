// Host-decided session access (ACP agents and native OpenCode): a safe
// session opens for writing in the same click, a held one is followed with
// a precise reason and only real actions, and writing comes back only
// through a fresh admission the host reports as free.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/opencode_chat.dart';

const claude = 'pcx:local:acp:claude';
const opencode = openCodeService;
const thread = 'original-session';

SessionAccess access({
  String mode = 'follow',
  String writer = 'native_client',
  String turn = 'idle',
  String reason = 'external_idle',
  String exclusion = '',
  AccessHolder? holder,
  bool canRelease = false,
  bool recheck = true,
  String provider = 'claude',
}) => SessionAccess(
  sessionId: thread,
  hostId: 'host-1',
  generation: 7,
  provider: provider,
  mode: mode,
  writer: writer,
  turn: turn,
  exclusion: exclusion,
  reason: reason,
  holder: holder,
  canRelease: canRelease,
  recheck: recheck,
);

final writable = access(
  mode: 'write',
  writer: 'this_host',
  reason: 'owned',
  exclusion: 'pocox',
  canRelease: true,
  recheck: false,
);

Future<FakeBridgeApi> openChat(
  WidgetTester t, {
  String service = claude,
  List<SessionAccess> opens = const [],
  Size size = const Size(1280, 900),
}) {
  final api = FakeBridgeApi()
    ..acpCapabilities[service] = service == opencode
        ? negotiatedOpenCodeCapabilities(generation: 7)
        : negotiatedAcpCapabilities(
            providerName: 'Claude',
            profileId: 'claude',
            generation: 7,
            nativeHistory: true,
          )
    ..metadataOnlyFollow = true
    ..readResult = const ThreadHistory(
      running: false,
      cwd: '/project',
      items: [],
    );
  api.sessionOpenResults.addAll(opens);
  return mountChat(t, api, service: service, threadId: thread, size: size);
}

Future<void> disposeChat(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  await frames(t);
  expect(t.takeException(), isNull);
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('a released original session opens for writing in one click', (
    t,
  ) async {
    final api = await openChat(t, opens: [writable]);
    expect(api.sessionOpenCalls, [thread]);
    expect(api.lastResumed, thread);
    expect(find.byKey(const Key('composer-input')), findsOneWidget);
    expect(find.byKey(const Key('access-panel-owned')), findsNothing);
    // No dialog and no Take Over step stand between the click and writing.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const Key('chat-takeover-action')), findsNothing);
    await disposeChat(t);
  });

  testWidgets('an idle native writer is followed with its exact reason', (
    t,
  ) async {
    final api = await openChat(
      t,
      opens: [
        access(holder: const AccessHolder(client: 'claude_code', pid: 4312)),
      ],
    );
    expect(find.byKey(const Key('access-panel-external_idle')), findsOneWidget);
    expect(
      find.text('Claude Code still has this session open'),
      findsOneWidget,
    );
    expect(find.textContaining('pid 4312'), findsOneWidget);
    // "No turn is running" is said apart from "someone else holds it".
    expect(find.textContaining('No turn is running'), findsOneWidget);
    expect(find.byKey(const Key('composer-input')), findsNothing);
    expect(find.byKey(const Key('access-check')), findsOneWidget);
    // Nothing offers to write over the holder.
    expect(find.byKey(const Key('access-continue')), findsNothing);
    expect(api.turnStartCount, 0);
    await disposeChat(t);
  });

  testWidgets('the view opens again only when the host reports no writer', (
    t,
  ) async {
    final api = await openChat(t, opens: [access(), writable]);
    // Still held: the re-check answers the same and nothing opens.
    api.sessionAccessResults.add(access());
    await t.pump(const Duration(seconds: 3));
    await frames(t);
    expect(api.sessionAccessCalls, hasLength(1));
    expect(api.sessionOpenCalls, hasLength(1));
    expect(find.byKey(const Key('composer-input')), findsNothing);
    // The holder closed it: the next check opens through a fresh admission.
    api.sessionAccessResults.add(access(writer: 'none', reason: 'released'));
    await t.pump(const Duration(seconds: 3));
    await frames(t);
    expect(api.sessionOpenCalls, hasLength(2));
    expect(find.byKey(const Key('composer-input')), findsOneWidget);
    await disposeChat(t);
  });

  testWidgets('a running external turn reads as running, not as writable', (
    t,
  ) async {
    await openChat(
      t,
      opens: [
        access(
          turn: 'running',
          reason: 'external_running',
          holder: const AccessHolder(client: 'claude_code'),
        ),
      ],
    );
    expect(
      find.byKey(const Key('access-panel-external_running')),
      findsOneWidget,
    );
    expect(
      find.text('Claude Code is running a turn in this session'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('composer-input')), findsNothing);
    await disposeChat(t);
  });

  testWidgets('another OpenCode process on the source never times into '
      'write access', (t) async {
    final api = await openChat(
      t,
      service: opencode,
      opens: [
        access(
          provider: 'opencode',
          turn: 'unknown',
          writer: 'unknown',
          reason: 'external_source_open',
          recheck: false,
        ),
      ],
    );
    expect(
      find.byKey(const Key('access-panel-external_source_open')),
      findsOneWidget,
    );
    expect(
      find.text('Another OpenCode process has this history source open'),
      findsOneWidget,
    );
    // No running label is invented, and quiet time grants nothing.
    expect(find.textContaining('running a turn'), findsNothing);
    await t.pump(const Duration(minutes: 2));
    await frames(t);
    expect(api.sessionOpenCalls, hasLength(1));
    expect(api.sessionAccessCalls, isEmpty);
    // Check now asks the host, explicitly.
    api.sessionAccessResults.add(
      access(
        provider: 'opencode',
        turn: 'unknown',
        writer: 'unknown',
        reason: 'external_source_open',
        recheck: false,
      ),
    );
    await t.tap(find.byKey(const Key('access-check')));
    await frames(t);
    expect(api.sessionAccessCalls, hasLength(1));
    expect(find.byKey(const Key('composer-input')), findsNothing);
    await disposeChat(t);
  });

  testWidgets('a POCOX host holder offers navigation only with its key', (
    t,
  ) async {
    await openChat(
      t,
      opens: [
        access(
          writer: 'pocox_host',
          reason: 'pocox_host',
          holder: const AccessHolder(
            client: 'pocox_host',
            hostName: 'studio',
            serviceKey: 'pcx:studio:acp:claude',
          ),
        ),
      ],
    );
    expect(find.byKey(const Key('access-open-holder')), findsOneWidget);
    expect(find.text('Open in studio'), findsOneWidget);
    await disposeChat(t);

    await openChat(
      t,
      opens: [
        access(
          writer: 'pocox_host',
          reason: 'pocox_host',
          holder: const AccessHolder(client: 'pocox_host'),
        ),
      ],
    );
    expect(find.byKey(const Key('access-panel-pocox_host')), findsOneWidget);
    expect(find.byKey(const Key('access-open-holder')), findsNothing);
    await disposeChat(t);
  });

  testWidgets('handing back keeps the draft and never takes the session '
      'again by itself', (t) async {
    final api = await openChat(t, opens: [writable]);
    await t.enterText(find.byKey(const Key('composer-input')), 'keep me');
    await t.tap(find.byTooltip('More').first);
    await frames(t);
    await t.tap(find.byKey(const Key('session-release')));
    await frames(t);
    expect(api.sessionReleaseCalls.single.sessionId, thread);
    expect(find.byKey(const Key('access-panel-released_here')), findsOneWidget);
    expect(find.byKey(const Key('access-continue')), findsOneWidget);
    // Nobody took it, yet nothing reacquires it.
    await t.pump(const Duration(minutes: 1));
    await frames(t);
    expect(api.sessionOpenCalls, hasLength(1));
    // Continue here is the explicit open.
    api.sessionOpenResults.add(writable);
    await t.tap(find.byKey(const Key('access-continue')));
    await frames(t);
    expect(api.sessionOpenCalls, hasLength(2));
    expect(composerText(t), 'keep me');
    expect(api.turnStartCount, 0);
    await disposeChat(t);
  });

  testWidgets('a withdrawn admission follows at once and keeps the draft', (
    t,
  ) async {
    final api = await openChat(t, opens: [writable]);
    await t.enterText(find.byKey(const Key('composer-input')), 'unsent');
    api.sessionAccessResults.add(
      access(writer: 'this_host', reason: 'transition'),
    );
    api.pushEvent(
      claude,
      const AppEvent(
        kind: 'acp/session/updated',
        threadId: thread,
        raw: '{"sessionId":"original-session","releasing":true}',
      ),
    );
    await frames(t);
    expect(find.byKey(const Key('composer-input')), findsNothing);
    expect(find.byKey(const Key('access-panel-transition')), findsOneWidget);
    // Changing hands is never taken as a free session.
    expect(api.sessionOpenCalls, hasLength(1));
    expect(api.turnStartCount, 0);
    await disposeChat(t);
  });

  for (final (device, size) in [
    ('phone', const Size(320, 640)),
    ('tablet', const Size(800, 1100)),
    ('desktop', const Size(1440, 900)),
  ]) {
    testWidgets('the access panel fits a $device', (t) async {
      await openChat(
        t,
        size: size,
        opens: [
          access(
            writer: 'pocox_host',
            reason: 'pocox_host',
            holder: const AccessHolder(
              client: 'pocox_host',
              hostName: 'a host with a rather long instance name',
              serviceKey: 'pcx:studio:acp:claude',
            ),
          ),
        ],
      );
      expect(t.takeException(), isNull);
      final check = t.getSize(find.byKey(const Key('access-check')));
      expect(check.height, greaterThanOrEqualTo(size.width < 720 ? 44 : 36));
      await disposeChat(t);
    });
  }
}
