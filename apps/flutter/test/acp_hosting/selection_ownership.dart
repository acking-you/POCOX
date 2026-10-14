part of '../acp_hosting_test.dart';

void _registerSelectionOwnership() {
  group('async lookups and names', () {
    testWidgets('an old lookup finishing late does not mark the new agent '
        'found', (t) async {
      final api = FakeBridgeApi();
      // The preset's lookup hangs; the user switches to a custom agent.
      final slow = Completer<void>();
      api.acpLocateGates['fixture-agent'] = slow;
      await _pumpDialog(t, api);
      await t.tap(find.byKey(const Key('agent-choice-preset:fixture')));
      await t.pump(const Duration(milliseconds: 400));
      await _chooseCustom(t);
      await t.enterText(
        find.byKey(const Key('acp-program-field')),
        'missing-agent',
      );
      // The new lookup has not fired yet (debounce) when the old one ends.
      await t.pump(const Duration(milliseconds: 100));
      slow.complete();
      await t.pump();
      expect(find.byKey(const Key('acp-program-found')), findsNothing);
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('acp-program-missing')), findsOneWidget);
    });

    testWidgets('a failed lookup is shown with a retry that settles', (
      t,
    ) async {
      final api = FakeBridgeApi()..acpLocateFailures.add('fixture-agent');
      await _pumpDialog(t, api);
      await _chooseAcp(t);
      expect(
        find.byKey(const Key('acp-program-locate-failed')),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await t.tap(find.byKey(const Key('acp-program-locate-retry')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('acp-program-locate-failed')), findsNothing);
      expect(find.byKey(const Key('acp-program-found')), findsOneWidget);
    });

    testWidgets('a file picked after switching agent is dropped', (t) async {
      final picker = _GatedPicker('/opt/agents/picked');
      final previous = fsel.FileSelectorPlatform.instance;
      fsel.FileSelectorPlatform.instance = picker;
      addTearDown(() => fsel.FileSelectorPlatform.instance = previous);
      final api = FakeBridgeApi();
      await _pumpDialog(t, api);
      await _chooseCustom(t);
      await t.tap(find.byKey(const Key('acp-program-browse')));
      await t.pump();
      expect(picker.opened, isTrue);
      await _chooseAcp(t);
      picker.gate.complete();
      await t.pumpAndSettle();
      final program = t.widget<TextField>(
        find.byKey(const Key('acp-program-field')),
      );
      expect(program.controller!.text, 'fixture-agent');
    });

    testWidgets('a suggested name moves off hosts that load later; a typed '
        'one stays', (t) async {
      final api = FakeBridgeApi();
      final c = await _pumpDialog(t, api);
      await _chooseAcp(t);
      TextField name() =>
          t.widget(find.byKey(const Key('acp-instance-name-field')));
      expect(name().controller!.text, 'fixture');
      // A host named `fixture` turns up (status loaded late).
      await api.appServeStartAcp(name: 'fixture', spec: _fixtureSpec);
      c.invalidate(localServeListProvider);
      await t.pumpAndSettle();
      expect(name().controller!.text, 'fixture-2');
      await t.enterText(
        find.byKey(const Key('acp-instance-name-field')),
        'mine',
      );
      await api.appServeStartAcp(
        name: 'other',
        spec: const AcpAgentSpec(
          profileId: 'x',
          displayName: 'X',
          program: 'x',
        ),
      );
      c.invalidate(localServeListProvider);
      await t.pumpAndSettle();
      expect(name().controller!.text, 'mine');
    });
  });

  group('Codex path', () {
    Future<_GatedPicker> picker(String path) async {
      final picker = _GatedPicker(path);
      final previous = fsel.FileSelectorPlatform.instance;
      fsel.FileSelectorPlatform.instance = picker;
      addTearDown(() => fsel.FileSelectorPlatform.instance = previous);
      return picker;
    }

    Future<void> browse(WidgetTester t, _GatedPicker picker) async {
      final button = find.byKey(const Key('browse-codex-btn'));
      await t.ensureVisible(button);
      await t.pumpAndSettle();
      await t.tap(button);
      await t.pump();
      expect(picker.opened, isTrue);
    }

    String path(WidgetTester t) => t
        .widget<TextField>(find.byKey(const Key('codex-path-field')))
        .controller!
        .text;

    testWidgets('a file picked after switching agent is dropped', (t) async {
      final pick = await picker('/opt/picked/codex');
      final api = FakeBridgeApi()..codexPath = null;
      await _pumpDialog(t, api);
      await browse(t, pick);
      await _chooseAcp(t);
      pick.gate.complete();
      await t.pumpAndSettle();
      await _chooseCodex(t);
      expect(path(t), isEmpty);
    });

    testWidgets('a path typed after opening the picker wins', (t) async {
      final pick = await picker('/opt/picked/codex');
      final api = FakeBridgeApi()..codexPath = null;
      await _pumpDialog(t, api);
      await browse(t, pick);
      await t.enterText(
        find.byKey(const Key('codex-path-field')),
        '/opt/typed/codex',
      );
      pick.gate.complete();
      await t.pumpAndSettle();
      expect(path(t), '/opt/typed/codex');
      await _start(t);
      expect(api.lastServeBinary, '/opt/typed/codex');
    });

    testWidgets('a file picked once starting began does not change the '
        'start', (t) async {
      final pick = await picker('/opt/picked/codex');
      final api = FakeBridgeApi()..codexPath = null;
      await _pumpDialog(t, api);
      await t.enterText(
        find.byKey(const Key('codex-path-field')),
        '/opt/typed/codex',
      );
      await browse(t, pick);
      final serving = Completer<void>();
      api.serveStartGate = serving;
      await t.ensureVisible(find.byKey(const Key('start-hosting-btn')));
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pump();
      pick.gate.complete();
      await t.pump();
      expect(path(t), '/opt/typed/codex');
      serving.complete();
      await t.pumpAndSettle();
      expect(api.lastServeBinary, '/opt/typed/codex');
    });

    testWidgets('a path chosen while detection runs survives it, even when '
        'its text is unchanged', (t) async {
      final pick = await picker('/opt/mine/codex');
      final api = FakeBridgeApi()..codexPath = null;
      await _pumpDialog(t, api);
      await t.enterText(
        find.byKey(const Key('codex-path-field')),
        '/opt/mine/codex',
      );
      await browse(t, pick);
      // Re-detect finds a codex on PATH, slowly. Browsing scrolled the
      // file control to the top, so the button above it is brought back
      // first (the scroll is immediate: one frame, no settling).
      api.codexPath = '/usr/local/bin/codex';
      final detecting = Completer<void>();
      api.codexLocateGate = detecting;
      final redetect = find.byKey(const Key('redetect-codex-btn'));
      await t.ensureVisible(redetect);
      await t.pump();
      final lookups = api.codexLocateCalls;
      await t.tap(redetect);
      // Detection shows an indeterminate progress bar: pump bounded frames.
      await t.pump();
      expect(api.codexLocateCalls, lookups + 1, reason: 'the lookup began');
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // The user's pick (the same text) lands during detection.
      pick.gate.complete();
      await t.pump();
      detecting.complete();
      await t.pump();
      await t.pumpAndSettle();
      expect(find.byKey(const Key('customize-codex-btn')), findsNothing);
      expect(path(t), '/opt/mine/codex');
      await _start(t);
      expect(api.lastServeBinary, '/opt/mine/codex');
    });

    testWidgets('an untouched path follows detection', (t) async {
      final api = FakeBridgeApi()..codexPath = null;
      await _pumpDialog(t, api);
      api.codexPath = '/usr/local/bin/codex';
      final detecting = Completer<void>();
      api.codexLocateGate = detecting;
      await t.tap(find.byKey(const Key('redetect-codex-btn')));
      await t.pump();
      detecting.complete();
      await t.pump();
      await t.pumpAndSettle();
      expect(find.byKey(const Key('customize-codex-btn')), findsOneWidget);
      await _start(t);
      expect(api.lastServeBinary, isNull, reason: 'the detected codex');
    });
  });

  group('start follows the chosen tile', () {
    testWidgets('Codex starts the native app-server', (t) async {
      final api = FakeBridgeApi();
      await _pumpDialog(t, api);
      await _start(t);
      expect(api.lastServeName, 'default');
      expect(api.acpServeCalls, isEmpty);
    });

    testWidgets('a preset, a saved agent and a custom agent start ACP', (
      t,
    ) async {
      final api = FakeBridgeApi();
      final c = await _pumpDialog(t, api);
      c
          .read(uiPrefsProvider.notifier)
          .saveAcpAgent(
            const AcpAgentSpec(
              profileId: 'custom-saved-1',
              displayName: 'Saved',
              program: '/opt/agents/saved',
            ),
          );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('agent-choice-saved:custom-saved-1')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await _start(t);
      expect(api.lastServeName, isNull, reason: 'no Codex start');
      expect(api.acpServeCalls.single.$2.profileId, 'custom-saved-1');
    });

    _sameNameTests();
  });
}

/// A saved configuration with the fixture preset's own profile id and name,
/// launched differently.
const _savedFixture = AcpAgentSpec(
  profileId: 'fixture',
  displayName: 'Fixture Agent',
  program: '/opt/fx/bin/fixture-agent',
  args: ['acp', '--port', '4100'],
);

/// The open ACP form's program and arguments (unfolding Advanced first).
Future<(String, List<String>)> _launchFields(WidgetTester t) async {
  await _openAdvanced(t, 'acp-advanced-toggle');
  String text(String key) =>
      t.widget<TextField>(find.byKey(Key(key))).controller!.text;
  final args = <String>[
    for (
      var i = 0;
      find.byKey(Key('acp-arg-field-$i')).evaluate().isNotEmpty;
      i++
    )
      text('acp-arg-field-$i'),
  ];
  return (text('acp-program-field'), args);
}

/// The choice whose tile holds the primary focus, if any.
String? _focusedChoice() {
  final context = FocusManager.instance.primaryFocus?.context;
  String? found;
  context?.visitAncestorElements((element) {
    final key = element.widget.key;
    if (key is ValueKey<String> && key.value.startsWith('agent-choice-')) {
      found = key.value.substring('agent-choice-'.length);
      return false;
    }
    return true;
  });
  return found;
}

void _sameNameTests() {
  testWidgets('a saved configuration named like a preset is told apart, '
      'and each fills its own launch settings', (t) async {
    final handle = t.ensureSemantics();
    final l10n = lookupAppLocalizations(const Locale('en'));
    final api = FakeBridgeApi();
    final prefs = _HeldPrefs(const UiPrefs(acpAgents: [_savedFixture]));
    final c = await _pumpDialog(t, api, prefs: prefs);
    final preset = find.byKey(const Key('agent-choice-preset:fixture'));
    final saved = find.byKey(const Key('agent-choice-saved:fixture'));
    final builtIn = find.byKey(const Key('agent-choice-builtin'));
    final mine = find.byKey(const Key('agent-choice-mine'));

    // Same name and mark, in different sections with their own headings.
    for (final tile in [preset, saved]) {
      expect(
        find.descendant(
          of: tile,
          matching: find.byKey(const Key('agent-icon-letter')),
        ),
        findsOneWidget,
      );
    }
    expect(find.descendant(of: builtIn, matching: preset), findsOneWidget);
    expect(find.descendant(of: mine, matching: saved), findsOneWidget);
    expect(find.descendant(of: builtIn, matching: saved), findsNothing);
    expect(find.descendant(of: mine, matching: preset), findsNothing);
    // ...and a distinct name for each, announced once.
    final name = _savedFixture.displayName;
    final presetLabel = '$name, ${l10n.agentChoicePreset}';
    final savedLabel = '$name, ${l10n.agentChoiceSaved}';
    expect(presetLabel, isNot(savedLabel));
    for (final (tile, label) in [(preset, presetLabel), (saved, savedLabel)]) {
      expect(
        t.getSemantics(tile),
        isSemantics(label: label, isButton: true, hasTapAction: true),
      );
      expect(find.bySemanticsLabel(label), findsOneWidget);
    }
    expect(find.bySemanticsLabel(name), findsNothing, reason: 'no bare title');
    for (final heading in [
      l10n.agentChoiceBuiltinTitle,
      l10n.agentChoiceSavedTitle,
    ]) {
      expect(
        t.getSemantics(find.text(heading)),
        isSemantics(label: heading, isHeader: true),
      );
    }

    // Both are reached by Tab, the preset first; Enter picks the saved one,
    // which brings its own program and arguments.
    final reached = <String>[];
    for (var i = 0; i < 12 && !reached.contains('saved:fixture'); i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      final choice = _focusedChoice();
      if (choice != null && !reached.contains(choice)) reached.add(choice);
    }
    expect(reached, containsAllInOrder(['preset:fixture', 'saved:fixture']));
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(t.getSemantics(saved), isSemantics(isSelected: true));
    expect(t.getSemantics(preset), isSemantics(isSelected: false));
    var (program, args) = await _launchFields(t);
    expect(program, _savedFixture.program);
    expect(args, _savedFixture.args);

    // The preset, picked through its semantics action, brings its defaults.
    // Unfolding Advanced scrolled the form; bring the tile back first.
    await t.ensureVisible(preset);
    await t.pumpAndSettle();
    t.semantics.tap(find.semantics.byLabel(presetLabel));
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(t.getSemantics(preset), isSemantics(isSelected: true));
    (program, args) = await _launchFields(t);
    expect(program, 'fixture-agent');
    expect(args, ['acp']);
    // Cancelling starts nothing and writes nothing.
    final cancel = find.text(l10n.cancel);
    await t.ensureVisible(cancel);
    await t.tap(cancel);
    await t.pumpAndSettle();
    expect(find.byType(LocalHostDialog), findsNothing);
    expect(api.acpServeCalls, isEmpty);
    expect(api.lastServeName, isNull);
    expect(prefs.written, isEmpty, reason: 'nothing saved or remembered');

    // Starting the saved one launches its settings and keeps it as it was.
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.ensureVisible(saved);
    await t.pumpAndSettle();
    expect(saved.hitTestable(), findsOneWidget);
    await t.tap(saved);
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    await _start(t);
    final (_, spec) = api.acpServeCalls.single;
    expect(spec.profileId, _savedFixture.profileId);
    expect(spec.program, _savedFixture.program);
    expect(spec.args, _savedFixture.args);
    final kept = (await c.read(uiPrefsProvider.future)).acpAgents;
    expect(kept, hasLength(1));
    expect(kept.single.displayName, _savedFixture.displayName);
    expect(kept.single.program, _savedFixture.program);
    expect(kept.single.args, _savedFixture.args);
    handle.dispose();
  });
}

extension on AppServeStatus {
  AppServeStatus copyForTest({required String name}) => AppServeStatus(
    name: name,
    device: device,
    alive: alive,
    appServiceKey: 'pcx:local:acp:$name',
    provider: provider,
    protocol: protocol,
    providerName: providerName,
    agentPhase: 'ready',
  );
}

const _fixtureSpec = AcpAgentSpec(
  profileId: 'fixture',
  displayName: 'Fixture Agent',
  program: 'fixture-agent',
  args: ['acp'],
);

/// The four host operations whose completion can outlive the dialog.
enum _Op { codexStart, acpStart, codexStop, acpStop }

/// The instance each operation acts on.
String _opName(_Op op) => switch (op) {
  _Op.codexStart => 'default',
  _Op.acpStart => 'fixture',
  _Op.codexStop => 'alpha',
  _Op.acpStop => 'beta',
};
