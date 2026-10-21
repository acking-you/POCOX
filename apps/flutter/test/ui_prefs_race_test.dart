// Per-name restore records and saved agents changed while the prefs file is
// still being read: every operation must land on the loaded file, in order,
// and the file written afterwards must match memory.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/ui_prefs.dart';

const _a = AutoHostPrefs(port: 18080, name: 'a');
const _b = AutoHostPrefs(port: 0, name: 'b');

AcpAgentSpec _agent(String id, {String program = 'agent'}) =>
    AcpAgentSpec(profileId: id, displayName: id, program: program);

AutoHostAcpPrefs _acp(String name) => AutoHostAcpPrefs(
  name: name,
  spec: _agent('fixture', program: 'fixture-agent'),
);

/// A store over a temporary file holding [saved], whose lookup waits for
/// the returned gate, so the initial load stays open until the test opens
/// it.
Future<(ProviderContainer, Completer<void>, File)> _store(UiPrefs saved) async {
  final dir = await Directory.systemTemp.createTemp('ui_prefs_race');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/ui_state.json');
  await file.writeAsString(jsonEncode(saved.toJson()));
  final gate = Completer<void>();
  UiPrefsStore.debugFileOverride = () async {
    await gate.future;
    return file;
  };
  addTearDown(() => UiPrefsStore.debugFileOverride = null);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  // Start the load; it now waits on the gate.
  container.read(uiPrefsProvider);
  return (container, gate, file);
}

/// Open the gate, wait for the load and replay ([UiPrefsStore.ready], not
/// the provider's `future`, which an interim snapshot already completes) and
/// every write, and return memory and the file's content.
Future<(UiPrefs, UiPrefs)> _settle(
  ProviderContainer c,
  Completer<void> gate,
  File file,
) async {
  final store = c.read(uiPrefsProvider.notifier);
  gate.complete();
  final memory = await store.ready;
  await store.debugWritesDone;
  // The provider publishes the settled snapshot too.
  await Future<void>.delayed(Duration.zero);
  expect(c.read(uiPrefsProvider).value, same(memory));
  final disk = UiPrefs.fromJson(
    jsonDecode(await file.readAsString()) as Map<String, dynamic>,
  );
  return (memory, disk);
}

List<String> _codex(UiPrefs p) => [for (final h in p.autoHostCodex) h.name];
List<String> _acpNames(UiPrefs p) => [for (final h in p.autoHostAcp) h.name];

void main() {
  test('saved A, add B during load: both kept', () async {
    final (c, gate, file) = await _store(const UiPrefs(autoHostCodex: [_a]));
    c.read(uiPrefsProvider.notifier).setAutoHost(_b);
    final (memory, disk) = await _settle(c, gate, file);
    expect(_codex(memory), ['a', 'b']);
    expect(_codex(disk), ['a', 'b']);
    expect(disk.autoHost?.name, 'a', reason: 'legacy key keeps first record');
  });

  test('update A during load keeps B and A\'s new settings', () async {
    final (c, gate, file) = await _store(
      const UiPrefs(autoHostCodex: [_a, _b]),
    );
    c
        .read(uiPrefsProvider.notifier)
        .setAutoHost(const AutoHostPrefs(port: 19090, name: 'a'));
    final (memory, disk) = await _settle(c, gate, file);
    expect(_codex(memory), ['b', 'a']);
    expect(memory.autoHostCodex.last.port, 19090);
    expect(_codex(disk), ['b', 'a']);
    expect(disk.autoHostCodex.last.port, 19090);
  });

  test('stop A before load finishes: A is not loaded back, B stays', () async {
    final (c, gate, file) = await _store(
      const UiPrefs(autoHostCodex: [_a, _b]),
    );
    c.read(uiPrefsProvider.notifier).clearAutoHost('a');
    final (memory, disk) = await _settle(c, gate, file);
    expect(_codex(memory), ['b']);
    expect(_codex(disk), ['b']);
  });

  test('add then remove, and remove then add, keep their order', () async {
    final (c, gate, file) = await _store(const UiPrefs(autoHostCodex: [_a]));
    c.read(uiPrefsProvider.notifier)
      ..setAutoHost(_b)
      ..clearAutoHost('b')
      ..clearAutoHost('a')
      ..setAutoHost(_a);
    final (memory, disk) = await _settle(c, gate, file);
    expect(_codex(memory), ['a']);
    expect(_codex(disk), ['a']);
  });

  test('ACP restore records follow the same rules', () async {
    final (c, gate, file) = await _store(
      UiPrefs(autoHostAcp: [_acp('x'), _acp('y')]),
    );
    c.read(uiPrefsProvider.notifier)
      ..clearAutoHostAcp('x')
      ..setAutoHostAcp(_acp('z'));
    final (memory, disk) = await _settle(c, gate, file);
    expect(_acpNames(memory), ['y', 'z']);
    expect(_acpNames(disk), ['y', 'z']);
  });

  test('saved agents: remove one, add another during load', () async {
    final (c, gate, file) = await _store(
      UiPrefs(acpAgents: [_agent('one'), _agent('two')]),
    );
    c.read(uiPrefsProvider.notifier)
      ..removeAcpAgent('one')
      ..saveAcpAgent(_agent('three'));
    final (memory, disk) = await _settle(c, gate, file);
    expect([for (final a in memory.acpAgents) a.profileId], ['two', 'three']);
    expect([for (final a in disk.acpAgents) a.profileId], ['two', 'three']);
  });

  test('unrelated fields edited during load are kept with the file', () async {
    final (c, gate, file) = await _store(
      const UiPrefs(autoHostCodex: [_a], themeMode: 'dark', guideSeen: true),
    );
    c.read(uiPrefsProvider.notifier).setLastService('pcx:dev:app:a');
    final (memory, disk) = await _settle(c, gate, file);
    expect(memory.themeMode, 'dark');
    expect(memory.guideSeen, isTrue);
    expect(memory.lastServiceKey, 'pcx:dev:app:a');
    expect(_codex(disk), ['a']);
    expect(disk.lastServiceKey, 'pcx:dev:app:a');
  });

  test(
    'a full restore list refuses a new name instead of dropping one',
    () async {
      final full = [
        for (var i = 0; i < UiPrefs.maxAutoHosts; i++)
          AutoHostPrefs(port: 0, name: 'h$i'),
      ];
      final (c, gate, file) = await _store(UiPrefs(autoHostCodex: full));
      await _settle(c, gate, file);
      c.read(uiPrefsProvider.notifier).setAutoHost(_b);
      expect(_codex(c.read(uiPrefsProvider).value!), [
        for (final h in full) h.name,
      ]);
    },
  );

  test('the provider future may resolve before the file is read; ready '
      'does not', () async {
    final (c, gate, file) = await _store(const UiPrefs(autoHostCodex: [_a]));
    final store = c.read(uiPrefsProvider.notifier);
    var ready = false;
    unawaited(store.ready.then((_) => ready = true));
    unawaited(store.setAutoHost(_b));
    // The interim snapshot is already data, without the file's record.
    final interim = await c.read(uiPrefsProvider.future);
    expect(_codex(interim), ['b']);
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse, reason: 'the file is still unread');
    final (memory, disk) = await _settle(c, gate, file);
    expect(ready, isTrue);
    expect(_codex(memory), ['a', 'b']);
    expect(_codex(disk), ['a', 'b']);
  });

  group('restore verdicts are taken on the loaded file', () {
    final full = [
      for (var i = 0; i < UiPrefs.maxAutoHosts; i++)
        AutoHostPrefs(port: 0, name: 'h$i'),
    ];
    final fullAcp = [
      for (var i = 0; i < UiPrefs.maxAutoHosts; i++) _acp('x$i'),
    ];
    final fullAgents = [
      for (var i = 0; i < UiPrefs.maxSavedAgents; i++) _agent('a$i'),
    ];

    test('a new Codex record during the load of a full file is refused, '
        'and every saved record kept', () async {
      final (c, gate, file) = await _store(UiPrefs(autoHostCodex: full));
      final verdict = c.read(uiPrefsProvider.notifier).setAutoHost(_b);
      // The interim snapshot would accept it; the verdict waits for the file.
      var decided = false;
      unawaited(verdict.then((_) => decided = true));
      await Future<void>.delayed(Duration.zero);
      expect(decided, isFalse);
      final (memory, disk) = await _settle(c, gate, file);
      expect(await verdict, isFalse);
      expect(_codex(memory), [for (final h in full) h.name]);
      expect(_codex(disk), [for (final h in full) h.name]);
    });

    test('an existing name in a full file is updated and accepted', () async {
      final (c, gate, file) = await _store(UiPrefs(autoHostCodex: full));
      final verdict = c
          .read(uiPrefsProvider.notifier)
          .setAutoHost(const AutoHostPrefs(port: 19090, name: 'h3'));
      final (memory, disk) = await _settle(c, gate, file);
      expect(await verdict, isTrue);
      expect(memory.autoHostCodex.last.port, 19090);
      expect(disk.autoHostCodex, hasLength(UiPrefs.maxAutoHosts));
    });

    test('a stop queued before the start makes room for it', () async {
      final (c, gate, file) = await _store(UiPrefs(autoHostCodex: full));
      final store = c.read(uiPrefsProvider.notifier)..clearAutoHost('h0');
      final verdict = store.setAutoHost(_b);
      final (memory, disk) = await _settle(c, gate, file);
      expect(await verdict, isTrue);
      expect(_codex(memory).last, 'b');
      expect(_codex(disk), hasLength(UiPrefs.maxAutoHosts));
      expect(_codex(disk), isNot(contains('h0')));
    });

    test('ACP records and saved agents report refusal the same way', () async {
      final (c, gate, file) = await _store(
        UiPrefs(autoHostAcp: fullAcp, acpAgents: fullAgents),
      );
      final store = c.read(uiPrefsProvider.notifier);
      final host = store.setAutoHostAcp(_acp('new'));
      final agent = store.saveAcpAgent(_agent('new'));
      final (memory, disk) = await _settle(c, gate, file);
      expect(await host, isFalse);
      expect(await agent, isFalse);
      expect(_acpNames(disk), [for (final h in fullAcp) h.name]);
      expect(disk.acpAgents, hasLength(UiPrefs.maxSavedAgents));
      expect(memory.acpAgents.map((a) => a.profileId), isNot(contains('new')));
    });

    test('after the load a verdict is immediate', () async {
      final (c, gate, file) = await _store(UiPrefs(autoHostCodex: full));
      await _settle(c, gate, file);
      final store = c.read(uiPrefsProvider.notifier);
      expect(await store.setAutoHost(_b), isFalse);
      store.clearAutoHost('h1');
      expect(await store.setAutoHost(_b), isTrue);
      await store.debugWritesDone;
      final disk = UiPrefs.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
      expect(_codex(disk).last, 'b');
    });
  });

  test('an operation right after the load is not undone by the build '
      'result', () async {
    final (c, gate, file) = await _store(const UiPrefs(autoHostCodex: [_a]));
    final store = c.read(uiPrefsProvider.notifier);
    gate.complete();
    await store.ready;
    // The build result may still be on its way to the provider state.
    store.setAutoHost(_b);
    await store.debugWritesDone;
    await Future<void>.delayed(Duration.zero);
    expect(_codex(c.read(uiPrefsProvider).value!), ['a', 'b']);
    final disk = UiPrefs.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
    expect(_codex(disk), ['a', 'b']);
  });

  test('disposing the store during the load writes nothing', () async {
    final (c, gate, file) = await _store(const UiPrefs(autoHostCodex: [_a]));
    final before = await file.readAsString();
    final store = c.read(uiPrefsProvider.notifier);
    final verdict = store.setAutoHost(_b);
    c.dispose();
    expect(await verdict, isFalse, reason: 'never stored');
    gate.complete();
    await store.ready;
    await store.debugWritesDone;
    expect(await file.readAsString(), before);
  });

  test('legacy single autoHost migrates to the list', () {
    final prefs = UiPrefs.fromJson({'autoHost': _a.toJson()});
    expect(_codex(prefs), ['a']);
  });
}
