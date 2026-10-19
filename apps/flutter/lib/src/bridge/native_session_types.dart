part of '../bridge_api.dart';

/// A bounded inventory from an explicitly selected local provider.
class NativeSessionList {
  const NativeSessionList({
    required this.sourceId,
    required this.location,
    required this.sessions,
    this.nextCursor,
    this.manageable = false,
  });
  final String sourceId;
  final String location;
  final List<LocalSession> sessions;
  final String? nextCursor;

  /// Sessions of this source can be renamed and deleted here (Grok).
  final bool manageable;
}

/// Public transcript window; generation changes invalidate retained pages.
class NativeSessionPage {
  const NativeSessionPage({
    required this.sourceId,
    required this.generation,
    required this.revision,
    required this.items,
    this.nextBefore,
    this.truncated = false,
  });
  final String sourceId;
  final String generation;
  final String revision;
  final List<ThreadItem> items;
  final String? nextBefore;
  final bool truncated;
}

/// Revision polling is independent of uncertain process ownership.
class NativeSessionRevision {
  const NativeSessionRevision({
    required this.sourceId,
    required this.generation,
    required this.revision,
    required this.liveness,
  });
  final String sourceId;
  final String generation;
  final String revision;
  final SessionLiveness liveness;
}
