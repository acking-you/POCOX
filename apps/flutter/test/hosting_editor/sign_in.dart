part of '../hosting_editor_test.dart';

void _signInTests() {
  testWidgets('official sign-in runs the editor codex on its own session', (
    t,
  ) async {
    _mockLauncher(t);
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _tapKey(t, 'host-source-official');
    expect(find.byKey(const Key('official-login-panel')), findsOneWidget);

    await _tapKeyPumped(t, 'codex-login-chatgpt');
    expect(api.signInSessions, hasLength(1));
    // The editor's codex and its default proxy, not the app's environment.
    expect(api.localSessionBinaries.single, '/usr/local/bin/codex');
    expect(api.localSessionProxies.single, 'http://127.0.0.1:11111');
    expect(find.byKey(const Key('codex-login-cancel')), findsOneWidget);

    // Cancel ends only this attempt's session.
    await _tapKeyPumped(t, 'codex-login-cancel');
    expect(api.signInSessions, isEmpty);
    expect(api.closedSignInSessions, ['local-0']);
    // Let the abandoned poll's timer run out; it touches nothing.
    await t.pump(const Duration(seconds: 3));
    expect(api.localCancels, isEmpty);
  });

  testWidgets('an existing credential is not this sign-in succeeding', (
    t,
  ) async {
    _mockLauncher(t);
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _tapKey(t, 'host-source-official');
    await _tapKeyPumped(t, 'codex-login-chatgpt');
    final session = api.signInSessions.single;

    // A stale auth.json or an API key: configured, but no completion.
    api.localAuth[session] = const CodexAuthStatus(
      authenticated: true,
      method: 'apikey',
    );
    await t.pump(const Duration(seconds: 2));
    await t.pump();
    expect(api.signInSessions, [session], reason: 'still waiting');
    expect(find.byKey(const Key('codex-login-cancel')), findsOneWidget);

    // A failed refresh is shown and the next poll retries.
    api.localAuthError = StateError('rpc lagging');
    await t.pump(const Duration(seconds: 2));
    await t.pump();
    expect(find.textContaining('rpc lagging'), findsOneWidget);

    // The server completes this login with a ChatGPT account.
    api.localAuth[session] = const CodexAuthStatus(
      authenticated: true,
      method: 'chatgpt',
      completed: true,
    );
    await t.pump(const Duration(seconds: 2));
    await t.pump();
    expect(api.signInSessions, isEmpty);
    expect(api.closedSignInSessions, [session]);
    expect(find.text(_l10n(t).codexSetupLoginSuccess), findsOneWidget);
  });

  testWidgets('two attempts own their sessions: a late open, status or '
      'logout of a closed one never touches the other', (t) async {
    _mockLauncher(t);
    final api = FakeBridgeApi();
    final showA = ValueNotifier(true);
    final signedIn = ValueNotifier<CodexSetupStatus?>(null);
    addTearDown(showA.dispose);
    addTearDown(signedIn.dispose);
    await t.pumpWidget(
      ProviderScope(
        overrides: [bridgeApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: Listenable.merge([showA, signedIn]),
              builder: (_, _) => Column(
                children: [
                  if (showA.value)
                    OfficialLoginPanel(
                      key: const Key('panel-a'),
                      status: signedIn.value,
                    ),
                  const OfficialLoginPanel(key: Key('panel-b'), status: null),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    Finder within(String panel, String key) => find.descendant(
      of: find.byKey(Key(panel)),
      matching: find.byKey(Key(key)),
    );
    Future<void> frames() async {
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
    }

    // A's open is held; B opens and is waiting while A is still pending.
    final lateOpen = Completer<void>();
    api.localSessionGate = lateOpen;
    await t.tap(within('panel-a', 'codex-login-chatgpt'));
    await frames();
    expect(api.signInSessions, isEmpty, reason: 'A is still opening');
    await t.tap(within('panel-b', 'codex-login-chatgpt'));
    await frames();
    expect(api.localSessionBinaries, hasLength(2), reason: 'both asked');
    final b = api.signInSessions.single;
    expect(within('panel-b', 'codex-login-cancel'), findsOneWidget);

    // A goes away, then its open answers late: only that session closes.
    showA.value = false;
    await frames();
    lateOpen.complete();
    await frames();
    expect(api.signInSessions, [b], reason: 'B keeps its own');
    expect(api.closedSignInSessions, hasLength(1));
    expect(api.closedSignInSessions.single, isNot(b));

    // A again, with its status poll held; it goes away and the held status
    // (a completed sign-in) answers late: B is not signed in by it.
    showA.value = true;
    await frames();
    await t.tap(within('panel-a', 'codex-login-chatgpt'));
    await frames();
    final a2 = api.signInSessions.last;
    expect(a2, isNot(b));
    final lateStatus = Completer<void>();
    api.localAuthGates[a2] = lateStatus;
    api.localAuth[a2] = const CodexAuthStatus(
      authenticated: true,
      method: 'chatgpt',
      completed: true,
    );
    await t.pump(const Duration(seconds: 2));
    await frames();
    showA.value = false;
    await frames();
    lateStatus.complete();
    await frames();
    expect(api.signInSessions, [b]);
    expect(api.closedSignInSessions, contains(a2));
    expect(within('panel-b', 'codex-login-cancel'), findsOneWidget);
    expect(within('panel-b', 'codex-login-info'), findsOneWidget);
    expect(
      find.text(_l10nOf(t).codexSetupLoginSuccess),
      findsNothing,
      reason: 'no panel took the late completion as its own',
    );

    // A signed in on disk: its sign-out is held, A goes away, the logout
    // answers late. B's session is untouched and never signed out.
    signedIn.value = const CodexSetupStatus(
      codexHome: '/Users/me/.codex',
      hasConfig: true,
      hasAuth: true,
      hasCustomProvider: false,
      authMode: 'chatgpt',
      needsSetup: false,
      promptVariant: 'default',
    );
    showA.value = true;
    await frames();
    final lateLogout = Completer<void>();
    api.localLogoutGate = lateLogout;
    await t.tap(within('panel-a', 'codex-logout-btn'));
    await frames();
    final a3 = api.signInSessions.last;
    expect(a3, isNot(b));
    showA.value = false;
    await frames();
    lateLogout.complete();
    await frames();
    expect(api.localLogoutSessions, isNot(contains(b)));
    expect(api.signInSessions, [b]);
    expect(api.closedSignInSessions, contains(a3));

    // Closing B ends only its own session.
    await t.tap(within('panel-b', 'codex-login-cancel'));
    await frames();
    expect(api.signInSessions, isEmpty);
    expect(api.closedSignInSessions.last, b);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a login completed without a ChatGPT account is not success', (
    t,
  ) async {
    _mockLauncher(t);
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _tapKey(t, 'host-source-official');
    await _tapKeyPumped(t, 'codex-login-chatgpt');
    final session = api.signInSessions.single;
    api.localAuth[session] = const CodexAuthStatus(
      authenticated: true,
      method: 'apikey',
      completed: true,
    );
    await t.pump(const Duration(seconds: 2));
    await t.pump();
    expect(find.text(_l10n(t).hostLoginNotOfficial), findsOneWidget);
    expect(find.text(_l10n(t).codexSetupLoginSuccess), findsNothing);
  });

  testWidgets('a late session open after a new attempt is closed, and the '
      'new attempt keeps its own', (t) async {
    _mockLauncher(t);
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _tapKey(t, 'host-source-official');

    final late = Completer<void>();
    api.localSessionGate = late;
    await _tapKeyPumped(t, 'codex-login-chatgpt');
    // Leaving closes the page; the late open must not survive it. The
    // spinner keeps animating until the page is gone, so pump finitely.
    await t.binding.handlePopRoute();
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
    await t.tap(find.byKey(const Key('host-leave-discard')));
    await t.pump();
    late.complete();
    await t.pumpAndSettle();
    expect(find.byType(HostingEditor), findsNothing);
    expect(api.signInSessions, isEmpty);
    expect(api.closedSignInSessions, hasLength(1));
    expect(api.localLogouts, 0);
  });
}
