part of '../bridge_api.dart';

/// Native controller projections, command admission and payload preparation.
abstract interface class ControllerBridgeApi {
  /// Create the native memory-only controller for one composer draft.
  ComposerControl composerCreate();

  /// Whether a host explicitly refused a turn before admitting it.
  bool turnErrorIsRefusal(String message);

  /// Check an explicit retry against native history without exporting its bodies.
  Future<bool> appTurnCommitted(
    String service,
    String thread,
    String text,
    List<String> images,
  );

  /// Native file index over the metadata of loaded edits.
  Future<ReviewIndex> reviewIndex(List<DiffModel> edits);

  /// Identity-only chronological merge computed by the native controller.
  Future<List<int>> historyMerge(
    List<String> currentIds,
    List<String> currentTurns,
    List<String> incomingIds,
    List<String> incomingTurns,
    List<String> turnOrder,
    bool olderPage,
  );

  /// Native parsed diff of the repo against its remote default branch.
  Future<DiffModel> appGitDiff(String serviceKey, String cwd);

  /// Read an explicitly selected local file into a native-owned handle.
  Future<Object> attachmentReadFile(String path);

  /// Release a prepared file immediately if its draft admission was revoked.
  void attachmentReleaseFile(Object file);

  /// Upload after the view rechecks its admission; bytes stay in Rust.
  Future<String> metaUploadPreparedFile(
    String serviceKey,
    String fileName,
    Object file,
    String expectedContext,
  );

  /// Capture the account/relay destination before reading attachment bytes.
  Future<String> metaUploadContext();

  /// Copy an image to its host session or draft project, with scoped admission.
  Future<String> metaUploadImageScoped(
    String serviceKey,
    String fileName,
    Uint8List bytes,
    String context, {
    String? thread,
    String? project,
  });

  /// Reject a context change before transmitting attachment bytes.
  Future<String> metaUploadFileScoped(
    String serviceKey,
    String fileName,
    Uint8List bytes,
    String context,
  );

  /// history (oldest first) followed by every new event live.
  Stream<void> logChanges();

  /// Filter the native log buffer without copying it to a permanent Dart ring.
  Future<LogView> logQuery({String? level, String keyword = ''});

  /// Record a bounded controller diagnostic in memory and on disk.
  void logRecord(String target, String message, {String level = 'INFO'});

  /// Clear retained history in the native log buffer.
  void logClear();
}
