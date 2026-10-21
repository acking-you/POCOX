import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/attachment_refs.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/tools/builtin_tools.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/composer_harness.dart';

/// Records how many turns had started when each grant arrived.
class _GrantOrderApi extends FakeBridgeApi {
  final turnsAtGrant = <int>[];

  @override
  Future<void> toolsGrant(
    String service,
    String conversation,
    List<String> tools,
  ) async {
    turnsAtGrant.add(turnStartCount);
    await super.toolsGrant(service, conversation, tools);
  }
}

const _offered = [
  ToolsBuiltinTool(id: 'services', title: 'Devices and services', summary: ''),
  ToolsBuiltinTool(
    id: 'share',
    title: 'Share a port',
    summary: '',
    gated: true,
  ),
  ToolsBuiltinTool(id: 'connect', title: 'Connect a service', summary: ''),
];

/// A tools overview where device [device] offers [_offered].
ToolsOverview _offeredBy(String device) => ToolsOverview(
  thisDevice: device,
  devices: [
    ToolsDevice(
      name: device,
      online: true,
      catalog: true,
      toolsEnabled: true,
      builtinTools: _offered,
    ),
  ],
);

/// Pick [ids] through the composer's `+` › Built-in tools.
Future<void> pickTools(WidgetTester t, List<String> ids) async {
  await t.tap(find.byKey(const Key('attach-menu-btn')));
  await composerFrames(t);
  await t.tap(find.byKey(const Key('builtin-tools-btn')));
  await composerFrames(t);
  for (final id in ids) {
    await t.tap(find.byKey(ValueKey('choice-$id')));
    await t.pump();
  }
  await t.sendKeyEvent(LogicalKeyboardKey.escape);
  await composerFrames(t);
}

void main() {
  test('the tools block ends the sent text and stays out of previews', () {
    final text = appendBuiltinTools(
      appendFileRefs('Ship it', ['/tmp/notes.txt']),
      ['share'],
    );
    final picked = splitBuiltinTools(text);
    expect(picked.ids, ['share']);
    expect(splitFileRefs(picked.text).text, 'Ship it');
    expect(previewWithoutFileRefs(text, 'untitled'), 'Ship it');
    expect(appendBuiltinTools('Ship it', const []), 'Ship it');
    // A list preview is the message truncated: inside the block, or inside
    // its opening tag.
    for (final cut in [text.indexOf('allows'), text.indexOf('ox_tools')]) {
      expect(
        previewWithoutFileRefs('${text.substring(0, cut)}…', 'untitled'),
        'Ship it',
      );
    }
    // A tool newer than this app is described to the agent by its host.
    final newer = appendBuiltinTools(
      'Ship it',
      ['share', 'tunnel'],
      summaries: {
        'tunnel': 'Open a tunnel (pocox `connect`, action `tunnel`).',
      },
    );
    expect(newer, contains('tunnel (pocox: Open a tunnel'));
    expect(splitBuiltinTools(newer).ids, ['share', 'tunnel']);
  });

  testWidgets('tools picked in the composer reach the agent, granted before '
      'its turn', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1280, 900);
    addTearDown(t.view.reset);
    // No echoed reply: the agent's text would carry the block verbatim.
    final api = _GrantOrderApi()
      ..autoCompleteTurn = false
      ..appThreads.add(
        const ThreadMeta(
          id: 'a',
          preview: 'Alpha',
          cwd: '/alpha',
          updatedAt: 1,
        ),
      )
      ..toolsOverviewValue = _offeredBy('host');
    await mountComposer(t, api);
    await pickTools(t, ['share', 'services']);
    expect(
      find.byKey(const ValueKey('builtin-tool-remove-share')),
      findsOneWidget,
    );

    await t.enterText(composerInput, 'Share the dev server');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await composerFrames(t);
    // In the host's order, and before the turn could ask for consent.
    final grant = api.toolsGrants.single;
    expect((grant.$1, grant.$2), (composerService, 'a'));
    expect(grant.$3, ['services', 'share']);
    expect(api.turnsAtGrant, [0]);
    final sent = splitBuiltinTools(api.lastTurnText!);
    expect(sent.text, 'Share the dev server');
    expect(sent.ids, ['services', 'share']);
    // The composer starts over; the sent message shows its tools as chips.
    expect(
      find.byKey(const ValueKey('builtin-tool-remove-share')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('builtin-tool-chip-share')),
      findsOneWidget,
    );
    expect(find.textContaining('<pocox_tools'), findsNothing);
  });

  testWidgets('a retry after the turn failed grants again the tools its '
      'text names', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1280, 900);
    addTearDown(t.view.reset);
    final api = FakeBridgeApi()
      ..autoCompleteTurn = false
      ..appThreads.add(
        const ThreadMeta(
          id: 'a',
          preview: 'Alpha',
          cwd: '/alpha',
          updatedAt: 1,
        ),
      )
      ..toolsOverviewValue = _offeredBy('host');
    await mountComposer(t, api);
    await pickTools(t, ['share']);
    await t.enterText(composerInput, 'Share the dev server');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await composerFrames(t);
    api.pushEvent(
      composerService,
      const AppEvent(
        kind: 'turn/failed',
        threadId: 'a',
        text: 'model overloaded',
        raw: '{}',
      ),
    );
    await composerFrames(t);
    await t.tap(find.widgetWithText(TextButton, 'Retry'));
    await composerFrames(t);
    expect(api.turnStartCount, 2);
    expect(splitBuiltinTools(api.lastTurnText!).ids, ['share']);
    expect(
      [for (final grant in api.toolsGrants) grant.$3],
      [
        ['share'],
        ['share'],
      ],
    );
  });

  testWidgets('tools picked while supplementing ride the supplement, '
      'granted first', (t) async {
    const acp = 'pcx:dev:acp:claude';
    final api = FakeBridgeApi()
      ..acpCapabilities[acp] = negotiatedAcpCapabilities(
        providerName: 'Claude',
        steer: true,
      )
      ..autoCompleteTurn = false
      ..toolsOverviewValue = _offeredBy('dev');
    await mountComposer(t, api, service: acp, thread: 'ses-1', settle: false);
    api.pushEvent(
      acp,
      const AppEvent(
        kind: 'turn/started',
        threadId: 'ses-1',
        raw: '{"turnId":"t1"}',
      ),
    );
    await composerFrames(t);
    await pickTools(t, ['share']);
    await t.tap(find.byKey(const Key('supplement-toggle')));
    await t.pump();
    await t.enterText(composerInput, 'and share it');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await composerFrames(t);
    expect(api.toolsGrants.single.$2, 'ses-1');
    expect(api.toolsGrants.single.$3, ['share']);
    final sent = splitBuiltinTools(api.supplementCalls.single.$3);
    expect(sent.text, 'and share it');
    expect(sent.ids, ['share']);
    expect(api.turnStartCount, 0, reason: 'never a prompt');
    // Taken with the input: nothing is left for a later turn.
    expect(
      find.byKey(const ValueKey('builtin-tool-remove-share')),
      findsNothing,
    );
  });
}
