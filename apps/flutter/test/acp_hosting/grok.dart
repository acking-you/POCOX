part of '../acp_hosting_test.dart';

const _grokPreset = AcpPreset(
  id: 'grok',
  displayName: 'Grok',
  program: 'grok',
  args: ['agent', '--no-leader', 'stdio'],
);

/// Answer url_launcher's platform channel, recording what was opened.
List<String> _recordLaunches(WidgetTester t) {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final opened = <String>[];
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
    call,
  ) async {
    if (call.method == 'launch') {
      opened.add((call.arguments as Map)['url'] as String);
    }
    return true;
  });
  addTearDown(
    () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
  return opened;
}

Future<void> _chooseSource(WidgetTester t, String source) async {
  final chip = find.byKey(Key('host-source-$source'));
  await t.ensureVisible(chip);
  await t.tap(chip);
  await t.pumpAndSettle();
}

void _registerGrok() {
  testWidgets('the Grok preset signs in with Grok in place and starts on the '
      'Grok account', (t) async {
    final opened = _recordLaunches(t);
    final api = FakeBridgeApi()..presets = const [_grokPreset];
    api.acpPrograms['grok'] = '/Users/me/.grok/bin/grok';
    await _pumpDialog(t, api);
    expect(find.byKey(const Key('agent-icon-grok')), findsOneWidget);
    await _chooseAcp(t, 'grok');
    // Its own configuration, the Grok account, or a custom provider.
    for (final source in ['inherited', 'official', 'custom']) {
      expect(find.byKey(Key('host-source-$source')), findsOneWidget);
    }
    await _chooseSource(t, 'official');
    expect(find.byKey(const Key('grok-login-none')), findsOneWidget);

    await t.ensureVisible(find.byKey(const Key('grok-login-btn')));
    await t.pump();
    await t.tap(find.byKey(const Key('grok-login-btn')));
    await t.pump();
    await t.pump();
    expect(find.byKey(const Key('grok-login-code')), findsOneWidget);
    expect(find.text('FAKE-CODE'), findsOneWidget);
    expect(opened.single, contains('user_code=FAKE-CODE'), reason: 'once');

    api.grokSignInAdvance(
      'grok-1',
      const GrokSignIn(phase: 'signed_in', email: 'me@example.com'),
    );
    await t.pump(const Duration(seconds: 1));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('grok-login-code')), findsNothing);
    expect(find.text('Signed in to Grok as me@example.com'), findsOneWidget);
    expect(api.grokPrograms, everyElement('grok'), reason: "the form's grok");

    await _start(t);
    final (name, runtime, input, _, _) = api.startConfiguredCalls.single;
    expect(name, 'grok');
    expect(runtime.agent?.profileId, 'grok');
    expect(input.source, 'official');
  });

  testWidgets('a pending Grok sign-in is cancelled, and so is one whose '
      'panel goes away', (t) async {
    _recordLaunches(t);
    final api = FakeBridgeApi()..presets = const [_grokPreset];
    api.acpPrograms['grok'] = '/Users/me/.grok/bin/grok';
    await _pumpDialog(t, api);
    await _chooseAcp(t, 'grok');
    await _chooseSource(t, 'official');
    await t.tap(find.byKey(const Key('grok-login-btn')));
    await t.pump();
    await t.pump();
    final cancel = find.byKey(const Key('grok-login-cancel'));
    await t.ensureVisible(cancel);
    await t.pump();
    await t.tap(cancel);
    await t.pumpAndSettle();
    expect(api.grokCancels, ['grok-1']);
    expect(find.byKey(const Key('grok-login-code')), findsNothing);

    final signIn = find.byKey(const Key('grok-login-btn'));
    await t.ensureVisible(signIn);
    await t.pump();
    await t.tap(signIn);
    await t.pump();
    await t.pump();
    // Choosing another model service removes the panel and its sign-in.
    await _chooseSource(t, 'inherited');
    expect(api.grokCancels, ['grok-1', 'grok-2']);
    expect(find.byKey(const Key('host-inherited-grok')), findsOneWidget);
  });
}
