part of '../../fake_bridge_api.dart';

mixin _FakeGrok on _FakeBridgeState {
  /// What [grokAccountStatus] answers.
  GrokAccount grokAccount = const GrokAccount(signedIn: false);

  /// Every program a Grok account call used (null: the installed `grok`).
  final List<String?> grokPrograms = [];

  /// Sign-in attempts by id; tests move them along with [grokSignInAdvance].
  final Map<String, GrokSignIn> grokSignIns = {};

  /// Cancelled sign-in attempts, in order.
  final List<String> grokCancels = [];

  /// Sign-outs so far.
  int grokSignOuts = 0;

  @override
  Future<GrokAccount> grokAccountStatus({String? program}) async {
    grokPrograms.add(program);
    return grokAccount;
  }

  @override
  Future<GrokAccount> grokSignOut({String? program}) async {
    grokPrograms.add(program);
    grokSignOuts++;
    grokAccount = const GrokAccount(signedIn: false);
    return grokAccount;
  }

  @override
  Future<String> grokSignInStart({String? program}) async {
    grokPrograms.add(program);
    final id = 'grok-${grokSignIns.length + 1}';
    grokSignIns[id] = const GrokSignIn(
      phase: 'waiting',
      url: 'https://accounts.x.ai/oauth2/device?user_code=FAKE-CODE',
      code: 'FAKE-CODE',
    );
    return id;
  }

  /// Move sign-in [id] to [state]; a `signed_in` state also signs in.
  void grokSignInAdvance(String id, GrokSignIn state) {
    grokSignIns[id] = state;
    if (state.phase == 'signed_in') {
      grokAccount = GrokAccount(
        signedIn: true,
        method: 'cached_token',
        email: state.email,
      );
    }
  }

  @override
  GrokSignIn grokSignInState(String attempt) =>
      grokSignIns[attempt] ?? (throw StateError('no such sign-in'));

  @override
  Future<void> grokSignInCancel(String attempt) async {
    grokCancels.add(attempt);
    grokSignIns[attempt] = const GrokSignIn(phase: 'cancelled');
  }
}
