part of '../bridge_api_rust.dart';

mixin _RustGrok implements BridgeApi {
  @override
  Future<GrokAccount> grokAccountStatus({String? program}) async =>
      _grokAccount(await frb.grokAccountStatus(program: program));

  @override
  Future<GrokAccount> grokSignOut({String? program}) async =>
      _grokAccount(await frb.grokSignOut(program: program));

  @override
  Future<String> grokSignInStart({String? program}) =>
      frb.grokSignInStart(program: program);

  @override
  GrokSignIn grokSignInState(String attempt) {
    final s = frb.grokSignInState(attempt: attempt);
    return GrokSignIn(
      phase: s.phase,
      url: s.url,
      code: s.code,
      email: s.email,
      error: s.error,
    );
  }

  @override
  Future<void> grokSignInCancel(String attempt) =>
      frb.grokSignInCancel(attempt: attempt);
}

GrokAccount _grokAccount(frb.GrokAccountDto a) =>
    GrokAccount(signedIn: a.signedIn, method: a.method, email: a.email);
