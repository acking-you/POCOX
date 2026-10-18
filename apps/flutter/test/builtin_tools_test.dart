import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/attachment_refs.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/tools/builtin_tools.dart';

import 'fake_bridge_api.dart';
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
      ..toolsOverviewValue = const ToolsOverview(
        thisDevice: 'host',
        devices: [
          ToolsDevice(
            name: 'host',
            online: true,
            catalog: true,
            toolsEnabled: true,
            builtinTools: _offered,
          ),
        ],
      );
    await mountComposer(t, api);
    await t.tap(find.byKey(const Key('attach-menu-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('builtin-tools-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('choice-share')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('choice-services')));
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
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
}
