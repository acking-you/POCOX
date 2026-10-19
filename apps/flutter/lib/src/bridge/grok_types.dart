part of '../bridge_api.dart';

/// What Grok Build reports about its sign-in on this computer.
class GrokAccount {
  /// Creates an account report.
  const GrokAccount({required this.signedIn, this.method, this.email});

  /// A sign-in (or an API key Grok stored) is in effect.
  final bool signedIn;

  /// The effective auth method id (`cached_token`, `xai.api_key`, ...).
  final String? method;

  /// The account email, when signed in with an account.
  final String? email;

  /// Signed in with an account rather than an API key.
  bool get account => signedIn && method != 'xai.api_key';
}

/// Where one Grok device sign-in is.
class GrokSignIn {
  /// Creates a sign-in state.
  const GrokSignIn({
    required this.phase,
    this.url,
    this.code,
    this.email,
    this.error,
  });

  /// `starting`, `waiting` (open [url]), `signed_in`, `failed`, `cancelled`.
  final String phase;

  /// The verification URL to open in a browser.
  final String? url;

  /// The code [url] confirms, for display.
  final String? code;

  /// The signed-in account, once done.
  final String? email;

  /// Why it failed.
  final String? error;

  /// The attempt is over.
  bool get ended =>
      phase == 'signed_in' || phase == 'failed' || phase == 'cancelled';
}
