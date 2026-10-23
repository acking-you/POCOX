part of '../app_session_screen.dart';

extension _SessionAttachments on _AppSessionState {
  // Composer attachments not yet sent; an entry with `processed == null` is
  // still being downscaled/re-encoded in a native worker.
  List<_Attachment> get _attachments => _draft.attachments;

  /// A single rounded composer surface: borderless multiline input on top, a
  /// row of compact setting pills + a circular send button below — modelled on
  /// common AI-chat composers rather than a bare TextField.
  /// Pick images to attach (photo library on Android/iOS via the system
  /// picker — no permission prompt; a file dialog on desktop). Each pick is
  /// processed (EXIF-bake / downscale / JPEG re-encode) on a native
  /// worker before it becomes sendable, showing a spinner chip meanwhile.
  Future<void> _pickImages() async {
    final draft = _draft;
    final ticket = _ticketFor(draft);
    final l10n = AppLocalizations.of(context);
    final messenger = ToastMessenger.of(context);
    if (!_attachGate.acceptsImages) {
      if (_attachGate.acceptsAny) messenger.error(l10n.imagesNotAccepted);
      return;
    }
    // Only IMAGE chips consume image slots — _attachments also holds document
    // chips, which have their own kMaxFilesPerMessage budget.
    final remaining =
        kMaxImagesPerMessage - _attachments.where((a) => !a.isFile).length;
    if (remaining <= 0) {
      messenger.error(l10n.imageTooMany(kMaxImagesPerMessage));
      return;
    }
    List<XFile> picked;
    try {
      // pickMultiImage's `limit` must be ≥ 2; fall back to the single picker
      // when only one slot is left.
      if (remaining == 1) {
        final one = await ImagePicker().pickImage(source: ImageSource.gallery);
        picked = [?one];
      } else {
        picked = await ImagePicker().pickMultiImage(limit: remaining);
      }
    } catch (_) {
      if (mounted) {
        messenger.error(l10n.imagePickFailed);
      }
      return;
    }
    if (picked.isEmpty || !mounted) return;
    // The view, its host or its image support may have changed while the
    // picker was open: admit against what holds now (see [AttachmentTicket]).
    final gate = _admitNow(draft, ticket);
    if (!gate.acceptsImages) {
      if (gate.acceptsAny) messenger.error(l10n.imagesNotAccepted);
      return;
    }
    if (picked.length > remaining) {
      // Some platforms ignore the picker's limit; enforce ours.
      picked = picked.sublist(0, remaining);
      messenger.error(l10n.imageTooMany(kMaxImagesPerMessage));
    }
    _updateState(() {
      for (final file in picked) {
        final att = _Attachment.image(
          id: _drafts.nextAttachmentId++,
          name: file.name,
        );
        att.draft = draft;
        att.ticket = ticket;
        draft.attachments.add(att);
        unawaited(_processAttachment(att, file));
      }
    });
    _drafts.save(draft, changed: true);
  }

  Future<void> _processAttachment(_Attachment att, XFile file) async {
    att.source = file;
    await _prepareAndUploadImage(
      att,
      () => localAttachmentPath(file.path)
          ? processImageFile(file.path)
          : file.readAsBytes().then(processImage),
    );
  }

  Future<void> _processImageBytes(_Attachment att, Uint8List bytes) async {
    att.sourceBytes = bytes;
    await _prepareAndUploadImage(att, () => processImage(bytes));
  }

  void _retryAttachment(_Attachment att) {
    if (att.error == null && att.hostError == null) return;
    // A retry is a new action: it is admitted by the view as it is now.
    final draft = att.draft;
    if (draft != null && identical(draft, _draft)) {
      att.ticket = _ticketFor(draft);
    }
    // Only the host mirror failed: the processed bytes are still good, so
    // retry the upload instead of decoding the image again.
    final retryHostOnly =
        att.error == null && att.processed != null && att.hostPath == null;
    att.error = null;
    att.hostError = null;
    _drafts.attachmentChanged(att);
    if (retryHostOnly) {
      unawaited(_prepareAndUploadImage(att, () async => att.processed!));
      return;
    }
    if (att.source case final file?) {
      unawaited(
        att.isFile
            ? _uploadAttachment(att, file)
            : _processAttachment(att, file),
      );
    } else if (att.sourceBytes case final bytes?) {
      unawaited(_processImageBytes(att, bytes));
    }
  }

  /// What this view's composer may take now (see [AttachmentGate]). Every
  /// attachment entry point — image picker, file picker, drop, paste —
  /// admits through it.
  AttachmentGate get _attachGate => AttachmentGate(
    editable: !_sending && !_externalWriterMode && !_guardianReadOnly,
    imageInput: _caps.imageInput,
  );

  /// The admission an asynchronous attachment into [draft] holds from now,
  /// granted by the view on screen.
  AttachmentTicket _ticketFor(_ComposerDraft draft) => AttachmentTicket(
    service: widget.serviceKey,
    revision: draft.admission,
    granted: identical(draft, _draft) ? _attachGate : AttachmentGate.closed,
  );

  /// What a result of [ticket] for [draft] may bring now.
  AttachmentGate _admitNow(_ComposerDraft draft, AttachmentTicket ticket) {
    if (!mounted) return AttachmentGate.closed;
    return ticket.now(
      service: widget.serviceKey,
      revision: draft.admission,
      onScreen: identical(draft, _draft) ? _attachGate : null,
    );
  }

  /// The view on screen stopped being editable (it turned read-only):
  /// nothing granted to its draft before may still arrive.
  void _revokeOnScreenAdmissions() => _draft.revokeAdmission();

  /// Pick document/file attachments (any type). Each is uploaded to the HOST
  /// right away (spinner chip while in flight) and later travels as a path
  /// reference in the turn text; image files route to the image pipeline
  /// (mirroring the codex TUI's `@file` mention) where images are accepted.
  Future<void> _pickFiles() async {
    final draft = _draft;
    final ticket = _ticketFor(draft);
    final l10n = AppLocalizations.of(context);
    final messenger = ToastMessenger.of(context);
    if (!_attachGate.acceptsAny) return;
    final remaining =
        kMaxFilesPerMessage - _attachments.where((a) => a.isFile).length;
    if (remaining <= 0) {
      messenger.error(l10n.fileTooMany(kMaxFilesPerMessage));
      return;
    }
    List<XFile> picked;
    try {
      picked = await openFiles();
    } catch (_) {
      if (mounted) {
        messenger.error(l10n.filePickFailed);
      }
      return;
    }
    _addFiles(picked, draft: draft, ticket: ticket);
  }

  /// Route a batch of files (picked, DRAGGED-and-dropped, or PASTED as paths)
  /// into attachments: images go through the local image pipeline, everything
  /// else uploads to the host as a path reference. Enforces the per-message
  /// image/file caps, surfacing a snackbar for anything dropped over-cap so a
  /// selection never silently vanishes. Shared by [_pickFiles], the drop
  /// target, and clipboard paste; admission goes through [_attachGate].
  ///
  /// A result that arrives later carries the [ticket] taken when the user
  /// acted, for the [draft] chosen then; it is admitted by what that
  /// ticket still allows (see [AttachmentTicket]). A synchronous call (a
  /// drop) is admitted by the view on screen.
  void _addFiles(
    List<XFile> picked, {
    _ComposerDraft? draft,
    AttachmentTicket? ticket,
  }) {
    if (picked.isEmpty || !mounted) return;
    final destination = draft ?? _draft;
    final admission = ticket ?? _ticketFor(destination);
    final gate = _admitNow(destination, admission);
    // XFile.name is the path basename on dart:io and can be empty for
    // synthetic files; the name reaches the host (and the chip label), so
    // never let it be blank.
    String nameOf(XFile f) => f.name.isNotEmpty ? f.name : 'file';
    if (!gate.acceptsAny) return;
    final attachments = destination.attachments;
    final l10n = AppLocalizations.of(context);
    final messenger = ToastMessenger.of(context);
    final remaining =
        kMaxFilesPerMessage - attachments.where((a) => a.isFile).length;
    var files = 0;
    var filesDropped = 0;
    var imagesDropped = 0;
    var imagesRefused = 0;
    var added = false;
    _updateState(() {
      for (final f in picked) {
        final name = nameOf(f);
        switch (gate.admit(name)) {
          case AttachmentAdmission.image:
            if (attachments.where((a) => !a.isFile).length <
                kMaxImagesPerMessage) {
              final att = _Attachment.image(
                id: _drafts.nextAttachmentId++,
                name: name,
              );
              att.draft = destination;
              att.ticket = admission;
              attachments.add(att);
              added = true;
              unawaited(_processAttachment(att, f));
            } else {
              imagesDropped++;
            }
          case AttachmentAdmission.document:
            if (files < remaining) {
              files++;
              final att = _Attachment.file(
                id: _drafts.nextAttachmentId++,
                name: name,
              );
              att.draft = destination;
              att.ticket = admission;
              attachments.add(att);
              added = true;
              unawaited(_uploadAttachment(att, f));
            } else {
              filesDropped++;
            }
          case AttachmentAdmission.refusedImage:
            imagesRefused++;
          case AttachmentAdmission.refused:
            break;
        }
      }
    });
    if (added) _drafts.save(destination, changed: true);
    if (imagesRefused > 0) messenger.error(l10n.imagesNotAccepted);
    if (filesDropped > 0) {
      messenger.error(l10n.fileTooMany(kMaxFilesPerMessage));
    }
    if (imagesDropped > 0) {
      messenger.error(l10n.imageTooMany(kMaxImagesPerMessage));
    }
  }

  /// Wrap the chat pane in a drag-and-drop target on desktop: a file dragged
  /// anywhere over the conversation attaches it (image or document), with a
  /// clear "drop to attach" overlay while hovering. A no-op on mobile/web.
  Widget _dropWrap(Widget child, AppLocalizations l10n) {
    if (!_isDesktop) return child;
    // Installed in every view so the subtree never remounts when the view
    // turns read-only; a read-only view simply shows and accepts nothing.
    return DropTarget(
      onDragEntered: (_) {
        if (_attachGate.acceptsAny) _updateState(() => _dragging = true);
      },
      onDragExited: (_) => _updateState(() => _dragging = false),
      onDragDone: (detail) {
        _updateState(() => _dragging = false);
        _onDrop(detail.files);
      },
      child: Stack(
        children: [
          child,
          if (_dragging)
            Positioned.fill(child: IgnorePointer(child: _dropOverlay(l10n))),
        ],
      ),
    );
  }

  Widget _dropOverlay(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: signalColor(scheme).withValues(alpha: 0.07),
      alignment: Alignment.center,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: surfacePanel(scheme),
          borderRadius: BorderRadius.circular(kPanelRadius),
          border: Border.all(color: signalColor(scheme), width: 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.file_download_outlined, color: signalColor(scheme)),
            const SizedBox(width: 10),
            Text(
              l10n.dropToAttach,
              style: TextStyle(
                color: signalColor(scheme),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// True on a desktop platform (where drag-and-drop + clipboard paste of
  /// images/files make sense). `defaultTargetPlatform` (not `dart:io`) so the
  /// web build still compiles.
  bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  /// Files dropped onto the chat → attach them exactly like a pick (nothing
  /// in a read-only view).
  void _onDrop(List<XFile> files) {
    if (!_attachGate.acceptsAny) return;
    _addFiles(files);
  }

  /// Ctrl/Cmd+V while the composer is focused: attach a clipboard IMAGE (raw
  /// bytes — no readable path, so processed directly) or clipboard FILES (by
  /// path). Runs alongside the text field's own text-paste (this never consumes
  /// the key event), so pasting text still works; only image/file clipboards
  /// add an attachment, and only where [_attachGate] admits them.
  Future<void> _onClipboardPaste() async {
    if (!mounted || !_attachGate.acceptsAny) return;
    final draft = _draft;
    final ticket = _ticketFor(draft);
    try {
      final img = await AppSessionScreen.debugClipboardImage();
      if (img != null && img.isNotEmpty) {
        if (!mounted) return;
        // The view, its host or its image support may have changed while
        // the clipboard was read.
        final gate = _admitNow(draft, ticket);
        if (!gate.acceptsAny) return;
        if (!gate.acceptsImages) {
          showToastError(
            context,
            AppLocalizations.of(context).imagesNotAccepted,
          );
          return;
        }
        if (draft.attachments.where((a) => !a.isFile).length >=
            kMaxImagesPerMessage) {
          showToastError(
            context,
            AppLocalizations.of(context).imageTooMany(kMaxImagesPerMessage),
          );
          return;
        }
        final att = _Attachment.image(
          id: _drafts.nextAttachmentId++,
          name: 'pasted-image.png',
        );
        att.draft = draft;
        att.ticket = ticket;
        draft.attachments.add(att);
        _drafts.save(draft, changed: true);
        unawaited(_processImageBytes(att, img));
        return;
      }
      final files = await AppSessionScreen.debugClipboardFiles();
      if (files.isNotEmpty && mounted) {
        _addFiles(
          [for (final p in files) XFile(p)],
          draft: draft,
          ticket: ticket,
        );
      }
    } catch (_) {
      // Clipboard read is best-effort; a text paste already happened natively.
    }
  }

  /// Whether [att] may still be uploaded: its admission still holds (see
  /// [AttachmentTicket]) — the file reads before an upload can take long.
  bool _mayUpload(_Attachment att) {
    final draft = att.draft, ticket = att.ticket;
    if (draft == null || ticket == null) return false;
    // Disposal ends this view's ownership/connection subscriptions. A file
    // still being read cannot rely on that stale admission. Keep it retryable
    // in its original draft; an upload already dispatched may still finish.
    if (!mounted ||
        !identical(draft, _draft) ||
        !_drafts.containsAttachment(att)) {
      return false;
    }
    final gate = _admitNow(draft, ticket);
    return att.isFile ? gate.acceptsAny : gate.acceptsImages;
  }

  Future<void> _uploadAttachment(_Attachment att, XFile file) async {
    att.source = file;
    final api = ref.read(bridgeApiProvider);
    final service = widget.serviceKey;
    final l10n = AppLocalizations.of(context);
    final tooLarge = l10n.fileTooLarge(kMaxFileBytes ~/ (1024 * 1024));
    final revoked = l10n.attachmentRevoked;
    try {
      final destination = await api.metaUploadContext();
      if (await file.length() > kMaxFileBytes) throw StateError(tooLarge);
      if (!_drafts.containsAttachment(att)) return;
      if (localAttachmentPath(file.path)) {
        final prepared = await api.attachmentReadFile(file.path);
        try {
          if (!_drafts.containsAttachment(att)) return;
          if (!_mayUpload(att)) throw StateError(revoked);
          att.hostPath = await api.metaUploadPreparedFile(
            service,
            att.name,
            prepared,
            destination,
          );
        } finally {
          api.attachmentReleaseFile(prepared);
        }
        _drafts.attachmentChanged(att);
        return;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > kMaxFileBytes) throw StateError(tooLarge);
      if (!_drafts.containsAttachment(att)) return;
      // Nothing leaves the device for a view that turned read-only or a
      // host that is gone while the file was read.
      if (!_mayUpload(att)) throw StateError(revoked);
      att.hostPath = await api.metaUploadFileScoped(
        service,
        att.name,
        bytes,
        destination,
      );
    } catch (e) {
      att.error = friendlyError(e);
    }
    _drafts.attachmentChanged(att);
  }

  /// Host filename for an image attachment: the picked basename when it has
  /// one, otherwise a generic stem, always with the extension of the PROCESSED
  /// bytes (a WebP re-encoded to JPEG must not land as `.webp`).
  String _imageUploadName(_Attachment att, ProcessedImage processed) {
    final basename = hostPathBasename(att.name).trim();
    final name = basename.isEmpty ? 'image' : basename;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    return '$stem.${sniffImageExtension(processed.bytes)}';
  }

  /// Mirror a processed image onto the HOST so an agent whose model cannot
  /// accept inline image input can still inspect it through a vision tool.
  /// Non-fatal: the inline data URL remains the source of truth for the turn,
  /// so a failed upload only drops the path reference.
  Future<void> _prepareAndUploadImage(
    _Attachment att,
    Future<ProcessedImage> Function() prepare,
  ) async {
    final api = ref.read(bridgeApiProvider);
    final drafts = _drafts;
    final service = widget.serviceKey;
    final thread = att.draft?.threadId;
    final project = att.draft?.project ?? _cwd ?? _automaticProject;
    final revoked = AppLocalizations.of(context).attachmentRevoked;
    // No intermediate ready notification: queue draining must wait for the
    // mirror even when native preparation finishes synchronously.
    att.uploading = true;
    att.hostError = null;
    drafts.attachmentChanged(att);
    try {
      String? destination;
      try {
        destination = await api.metaUploadContext();
      } catch (e) {
        att.hostError = friendlyError(e);
      }
      if (!drafts.containsAttachment(att)) return;
      try {
        att.processed = await prepare();
        att.sourceBytes = null;
      } catch (e) {
        att.error = friendlyError(e);
        return;
      }
      if (!drafts.containsAttachment(att) || destination == null) return;
      if (!_mayUpload(att)) throw StateError(revoked);
      final processed = att.processed!;
      att.hostPath = await api.metaUploadImageScoped(
        service,
        _imageUploadName(att, processed),
        processed.bytes,
        destination,
        thread: thread,
        project: project,
      );
    } catch (e) {
      att.hostError = friendlyError(e);
    } finally {
      att.uploading = false;
      drafts.attachmentChanged(att);
    }
  }

  Widget _attachmentStrip(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final scale = MediaQuery.of(context).devicePixelRatio;
    // Every staged IMAGE, in strip order — the set a preview can page through,
    // so opening one and swiping reaches the others (a per-tile viewer would
    // strand each image alone). Files have no pixels, so they aren't in it.
    final staged = [
      for (final a in _attachments)
        if (!a.isFile)
          if (a.processed case final p?) p.bytes,
    ];
    return SizedBox(
      // The remove button overhangs the tile's top corner, so the strip is
      // taller than the tiles it holds.
      height: kAttachmentTileSide + 8,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final att = _attachments[i];
          // Where this tile's image sits among the previewable ones. Counted
          // over the same filter as `staged` so a mixed strip (a file between
          // two images) still opens the picture the user actually clicked.
          final previewIndex = att.isFile || att.processed == null
              ? -1
              : _attachments
                    .take(i)
                    .where((a) => !a.isFile && a.processed != null)
                    .length;
          final Widget body;
          if (att.error != null) {
            body = Tooltip(
              message: '${att.name}: ${att.error}',
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    AppIcons.refresh,
                    size: 18,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  Text(
                    l10n.retry,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, height: 1.2),
                  ),
                  Text(
                    att.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, height: 1.1),
                  ),
                ],
              ),
            );
          } else if (!att.ready) {
            body = const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          } else if (att.isFile) {
            // Uploaded document: icon + filename tile.
            body = Tooltip(
              message: att.name,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      AppIcons.description_outlined,
                      size: 22,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      att.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 9),
                    ),
                  ],
                ),
              ),
            );
          } else if (att.processed case final processed?) {
            body = Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(
                  processed.bytes,
                  fit: BoxFit.cover,
                  // 2× the box so a landscape image's SHORT edge reaches the
                  // square cover box without upscaling.
                  cacheWidth: (kAttachmentTileSide * scale * 2).round(),
                  gaplessPlayback: true,
                ),
                if (att.hostError != null)
                  Positioned(
                    top: 2,
                    right: 2,
                    child: Tooltip(
                      message: att.hostError!,
                      child: const Icon(
                        AppIcons.warning_amber_rounded,
                        size: 14,
                      ),
                    ),
                  ),
              ],
            );
          } else {
            // Unreachable: an image attachment is `ready` iff processed is
            // set — kept bang-free per repo style.
            body = const SizedBox.shrink();
          }
          return AttachmentTile(
            key: Key('attachment-${att.id}'),
            removeKey: Key('attachment-remove-${att.id}'),
            removeTooltip: att.isFile ? l10n.removeFile : l10n.removeImage,
            onRemove: () {
              _updateState(() => _attachments.remove(att));
              _saveDraft();
            },
            // A staged image opens the same viewer a sent one does, so you can
            // check what you attached BEFORE sending it. A file has no pixels
            // to show, and an image still processing has none yet.
            onTap: att.error != null || att.hostError != null
                ? () => _retryAttachment(att)
                : previewIndex < 0
                ? null
                : () => ImageViewerPage.show(context, staged, previewIndex),
            tapTooltip: att.error != null || att.hostError != null
                ? l10n.retry
                : previewIndex < 0
                ? null
                : l10n.previewImage,
            child: body,
          );
        },
      ),
    );
  }
}
