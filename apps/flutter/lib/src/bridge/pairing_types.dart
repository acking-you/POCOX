part of '../bridge_api.dart';

/// A pairing call the backend refused, or that could not be made.
class PairingFailure implements Exception {
  /// Creates a failure.
  const PairingFailure({
    required this.code,
    required this.message,
    this.retryAfterSecs,
    this.operationId,
    this.graceDeadline,
  });

  /// The backend's stable reason (`device_superseded`, `preview_stale`, ...),
  /// `signed_out` for a session with no saved identity, `no_device` when this
  /// backend has no identity here for the call to act on, or `failed` for anything
  /// else. Match on this, never on [message].
  final String code;

  /// For the log. Holds no secret, code or pairing link.
  final String message;

  /// Seconds to wait before trying again.
  final int? retryAfterSecs;

  /// The pending operation this waits on, when it is this device's own.
  final String? operationId;

  /// For a superseded secret, when its overlap ends (unix seconds).
  final int? graceDeadline;

  @override
  String toString() => 'PairingFailure($code)';
}

/// A raw hardware identifier a platform adapter read for one explicit action.
/// Rust derives a key from it and drops it. Desktops never pass one.
class NativeHardwareHint {
  /// Creates a hint.
  const NativeHardwareHint({required this.source, required this.rawId});

  /// The adapter's source: `android_id`.
  final String source;

  /// The raw identifier.
  final String rawId;
}

/// A native device store's answer to a read.
class NativeStoreAnswer {
  /// Creates an answer.
  const NativeStoreAnswer({this.value, this.error});

  /// The record; null when there is none.
  final String? value;

  /// Why a record that exists cannot be read, which never becomes a new device.
  final String? error;
}

/// This device's session. Holds no token.
@immutable
class PairingSession {
  /// Creates a session view.
  const PairingSession({
    required this.deviceId,
    required this.accountId,
    required this.label,
    required this.activated,
    this.membershipChange,
    this.membershipChangedAt,
  });

  /// This device's id.
  final String deviceId;

  /// Its current user.
  final String accountId;

  /// Its display name.
  final String label;

  /// Whether the user has set it up.
  final bool activated;

  /// Its last transition: `linked`, `left`, `removed` or `unknown`.
  final String? membershipChange;

  /// When that was (unix seconds).
  final int? membershipChangedAt;
}

/// This device's own code.
@immutable
class PairingCode {
  /// Creates a code view.
  const PairingCode({
    required this.code,
    required this.uri,
    required this.issuedAt,
    required this.nextRotationAt,
    required this.paused,
  });

  /// The code as people read it: `K7M2-F9QX-3RTB`.
  final String code;

  /// What its QR code carries.
  final String uri;

  /// When it was issued (unix seconds, server time).
  final int issuedAt;

  /// Earliest rotation (unix seconds, server time).
  final int nextRotationAt;

  /// Whether linking through it is paused.
  final bool paused;
}

/// A device ready to show its code.
@immutable
class PairingPrepared {
  /// Creates a prepared device.
  const PairingPrepared({required this.session, required this.code});

  /// Its session.
  final PairingSession session;

  /// Its code.
  final PairingCode code;
}

/// A membership change, which may still be under way.
@immutable
class PairingOperation {
  /// Creates an operation view.
  const PairingOperation({
    required this.id,
    required this.kind,
    required this.status,
    this.error,
    this.caughtUp = true,
  });

  /// Its id.
  final String id;

  /// `link`, `leave`, `remove`, `restore` or `retake`.
  final String kind;

  /// `pending`, `completed`, `failed` or `unknown`. Never repeat a pending
  /// action: read it with [PairingBridgeApi.pairingSettle].
  final String status;

  /// Why it failed.
  final String? error;

  /// For a completed one, whether this installation has caught up with it. If
  /// not the change still stands: [PairingBridgeApi.pairingSettle] tries again.
  final bool caughtUp;
}

/// One reading of this device's identity.
@immutable
class PairingStatus {
  /// Creates a status.
  const PairingStatus({
    required this.state,
    required this.backend,
    required this.activeHere,
    this.session,
    this.graceDeadline,
    this.pending = const [],
    this.failed = const [],
    this.parkedGithub,
  });

  /// `no_device`, `inactive`, `active`, `removed`, `superseded`, `unknown` or
  /// `pending`.
  final String state;

  /// The canonical backend.
  final String backend;

  /// Whether this identity is the active account here.
  final bool activeHere;

  /// The session, when one could be issued.
  final PairingSession? session;

  /// For a superseded secret, when its overlap ends (unix seconds).
  final int? graceDeadline;

  /// Changes whose result is not in yet, which survive a restart.
  final List<PairingOperation> pending;

  /// Changes that recently turned out not to have happened, with why.
  final List<PairingOperation> failed;

  /// The login of a GitHub session set aside here, if any.
  final String? parkedGithub;
}

/// A device shown before confirming a group.
@immutable
class PairingPreviewDevice {
  /// Creates a device view.
  const PairingPreviewDevice({
    required this.id,
    required this.name,
    required this.lastActiveDay,
  });

  /// Its id, which a restore names as its target.
  final String id;

  /// Its display name.
  final String name;

  /// The day it was last active, in days since the unix epoch.
  final int lastActiveDay;
}

/// What a code leads to. Nothing has changed yet.
@immutable
class PairingPreview {
  /// Creates a preview.
  const PairingPreview({
    required this.ticket,
    required this.expiresAt,
    required this.targetDeviceId,
    required this.alreadyMember,
    required this.devices,
  });

  /// What confirming names.
  final String ticket;

  /// When the ticket stops working (unix seconds).
  final int expiresAt;

  /// The device whose code this is.
  final String targetDeviceId;

  /// Whether this device is already in that group.
  final bool alreadyMember;

  /// The group's devices.
  final List<PairingPreviewDevice> devices;
}

/// One device in this group.
@immutable
class PairingDevice {
  /// Creates a device view.
  const PairingDevice({
    required this.id,
    required this.name,
    required this.joinedAt,
    required this.lastActiveDay,
    required this.activated,
    required this.isSelf,
    this.platform,
  });

  /// Its id.
  final String id;

  /// Its display name.
  final String name;

  /// When it joined (unix seconds).
  final int joinedAt;

  /// The day it was last active, in days since the unix epoch.
  final int lastActiveDay;

  /// Whether it has been set up. An inactive peer hosts nothing.
  final bool activated;

  /// Whether this is this device.
  final bool isSelf;

  /// Its platform label.
  final String? platform;
}

/// A recovery request waiting on a member.
@immutable
class PairingRecoveryAsk {
  /// Creates a request view.
  const PairingRecoveryAsk({
    required this.requestId,
    required this.targetDeviceId,
    required this.requesterName,
    required this.matchingId,
    required this.expiresAt,
  });

  /// Its id, which an answer must name.
  final String requestId;

  /// The device it asks to restore.
  final String targetDeviceId;

  /// The requester's self-reported name. Does not identify anyone.
  final String requesterName;

  /// Compare with the requester's screen.
  final String matchingId;

  /// When it expires (unix seconds).
  final int expiresAt;
}

/// One page of this group.
@immutable
class PairingDevices {
  /// Creates a page.
  const PairingDevices({
    required this.devices,
    required this.pendingRequests,
    this.nextCursor,
  });

  /// Its devices.
  final List<PairingDevice> devices;

  /// Requests a member can answer.
  final List<PairingRecoveryAsk> pendingRequests;

  /// Pass back for the next page.
  final String? nextCursor;
}

/// Where this device's recovery request stands.
@immutable
class PairingRestoreRequest {
  /// Creates a request view.
  const PairingRestoreRequest({
    required this.requestId,
    required this.status,
    this.matchingId,
    this.expiresAt,
    this.targetDeviceId,
    this.devices = const [],
  });

  /// Its id.
  final String requestId;

  /// `pending`, `approved`, `denied`, `expired`, `stale` or `unknown`.
  final String status;

  /// Shown on both devices to tell this request from an impostor.
  final String? matchingId;

  /// When it stops being answerable (unix seconds).
  final int? expiresAt;

  /// Approved only: the device this would restore.
  final String? targetDeviceId;

  /// Approved only: the group's devices, to confirm before anything changes.
  final List<PairingPreviewDevice> devices;
}

/// Pairing-code login. Everything leaves the active account alone except what the
/// user explicitly confirms: [pairingActivate], [pairingLink] and
/// [pairingRestoreConfirm]. Every call but [pairingParseInvitation] and
/// [pairingInstallNativeStore] can throw a [PairingFailure].
abstract interface class PairingBridgeApi {
  /// Keep the device store in a platform's secure storage for this run. Call once
  /// at startup on mobile, before any other pairing call; desktops never do.
  /// [lockDir] is an app-private directory. [read] and [write] take an opaque slot
  /// name. [write] returns only once the record is durable, and answers a failure
  /// as text: neither may throw. A call that never answers fails after a while,
  /// and a new engine calling this again replaces an adapter that stopped answering.
  Future<void> pairingInstallNativeStore({
    required String lockDir,
    required Future<NativeStoreAnswer> Function(String slot) read,
    required Future<String?> Function(String slot, String value) write,
  });

  /// One reading of this device's identity, settling what can be settled.
  Future<PairingStatus> pairingStatus({String? backend});

  /// Opening sign-in: find or create this device's identity and its code. Changes
  /// no active account or hosting, and sends no hardware hint.
  Future<PairingPrepared> pairingPrepare({String? label, String? backend});

  /// Get started, or Continue: set this device up and make it the active account
  /// here. Hosts stopped for a removal start again.
  Future<PairingSession> pairingActivate({
    NativeHardwareHint? hint,
    String? backend,
  });

  /// This device's current code.
  Future<PairingCode> pairingCode({String? backend});

  /// Pause or resume linking through this device's code.
  Future<PairingCode> pairingSetPaused({required bool paused, String? backend});

  /// Replace this device's code. `rate_limited` with a wait before a day passes.
  Future<PairingCode> pairingRotate({String? backend});

  /// The code in a scanned invitation, or null when it is not one. Scanning
  /// executes nothing: pass the code to [pairingPreview].
  String? pairingParseInvitation(String uri);

  /// Look up a typed or scanned code. Changes nothing.
  Future<PairingPreview> pairingPreview(String code, {String? backend});

  /// Confirm a preview. [leaveCurrent] is the user's explicit confirmation of
  /// leaving current peers and every installation sharing this identity.
  Future<PairingOperation> pairingLink({
    required String ticket,
    required bool leaveCurrent,
    NativeHardwareHint? hint,
    String? backend,
  });

  /// Move this device out of its group, after the user confirmed.
  Future<PairingOperation> pairingLeave({String? backend});

  /// Reconcile every change saved on this device, without repeating any. Call at
  /// start and from a pending screen.
  Future<List<PairingOperation>> pairingSettle({String? backend});

  /// One page of this device's group.
  Future<PairingDevices> pairingDevices({String? cursor, String? backend});

  /// Rename a device in this group.
  Future<void> pairingRenameDevice({
    required String deviceId,
    required String name,
    String? backend,
  });

  /// Remove a device from this group, after the user confirmed.
  Future<PairingOperation> pairingRemoveDevice(
    String deviceId, {
    String? backend,
  });

  /// Allow or deny the exact recovery request a member sees. Allowing changes
  /// nothing until the requester confirms.
  Future<void> pairingDecideRestore({
    required String deviceId,
    required String requestId,
    required bool allow,
    String? backend,
  });

  /// Ask this device's former group to let it back. `not_found` when there is
  /// nothing to ask with: entering a code and continuing as new stay open.
  Future<PairingRestoreRequest> pairingRestoreRequest({
    NativeHardwareHint? hint,
    String? backend,
  });

  /// Where this device's recovery request stands.
  Future<PairingRestoreRequest> pairingRestorePoll(
    String requestId, {
    String? backend,
  });

  /// Confirm a restore, once the user has seen the group's devices: a [ticket]
  /// and [targetDeviceId] from a code's preview, or an approved [requestId].
  /// [retake] ends old authorization at once and rotates the code.
  Future<PairingOperation> pairingRestoreConfirm({
    String? ticket,
    String? targetDeviceId,
    String? requestId,
    bool retake = false,
    NativeHardwareHint? hint,
    String? backend,
  });

  /// A superseded or unknown identity's way forward, on the user's choice: start
  /// as a new inactive device. Refused while the identity still works.
  Future<PairingPrepared> pairingStartOver({String? label, String? backend});

  /// Make the GitHub session set aside here the active account again, for
  /// [backend] when named, else this installation's or the only one. Hosts stop
  /// first and start again under GitHub. Returns its login, or null when none was
  /// set aside. Refused while a GitHub session is already active here.
  Future<String?> pairingResumeGithub({String? backend});
}
