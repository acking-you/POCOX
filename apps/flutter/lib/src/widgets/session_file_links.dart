import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/file_exports.dart';
import 'package:pocox/src/file_links.dart';
import 'package:pocox/src/widgets/app_toast.dart';
import 'package:pocox/src/widgets/file_preview.dart';
import 'package:pocox/src/widgets/links.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/error_format.dart';
import 'package:pocox/src/service_key.dart';
import 'package:pocox/src/tools/tools_actions.dart';
import 'package:pocox/src/tools/tools_providers.dart';
import 'package:pocox/src/widgets/app_dialog.dart';

const _previewLimit = 8 * 1024 * 1024;
const _textLimit = 1024 * 1024;

/// Captures the host and session for each explicit transcript link action.
class SessionFileLinks extends StatelessWidget {
  const SessionFileLinks({
    super.key,
    required this.api,
    required this.serviceKey,
    required this.threadId,
    required this.cwd,
    required this.child,
  });
  final BridgeApi api;

  /// Null for a viewer explicitly reading this device's local sessions.
  final String? serviceKey;
  final String? threadId;
  final String? cwd;
  final Widget child;

  @override
  Widget build(BuildContext context) => SessionLinkScope(
    open: (context, href) async {
      final uri = Uri.tryParse(href.trim());
      if (uri != null && isHostLocalWebUrl(uri)) {
        await showAppDialog<void>(
          context: context,
          builder: (_) =>
              _HostWebLink(api: api, serviceKey: serviceKey, url: href),
        );
        return true;
      }
      final link = FileLink.parse(href, cwd: cwd);
      if (link == null) return false;
      await showAppDialog<void>(
        context: context,
        builder: (_) => _FileLinkDialog(
          api: api,
          serviceKey: serviceKey,
          threadId: threadId,
          link: link,
        ),
      );
      return true;
    },
    child: child,
  );
}

class _HostWebLink extends StatefulWidget {
  const _HostWebLink({
    required this.api,
    required this.serviceKey,
    required this.url,
  });
  final BridgeApi api;
  final String? serviceKey;
  final String url;
  @override
  State<_HostWebLink> createState() => _HostWebLinkState();
}

class _HostWebLinkState extends State<_HostWebLink> {
  bool _checking = true;
  bool _sharing = false;

  /// The app's providers, where the agent tools are (absent in previews).
  ProviderContainer? get _container => context
      .getInheritedWidgetOfExactType<UncontrolledProviderScope>()
      ?.container;

  /// The host's device, when it can share a port on request (a newer POCOX
  /// reporting its catalog).
  String? get _sharingDevice {
    final key = widget.serviceKey;
    final container = _container;
    if (key == null || container == null) return null;
    final device = parseServiceKey(key).device;
    final known = container
        .read(toolsOverviewProvider)
        .devices
        .any((d) => d.name == device && d.catalog);
    return known ? device : null;
  }

  /// Ask the host to share the link's port, then open it here.
  Future<void> _shareAndOpen(String device) async {
    final uri = Uri.parse(widget.url.trim());
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    final path =
        (uri.path.isEmpty ? '/' : uri.path) +
        (uri.hasQuery ? '?${uri.query}' : '') +
        // A hash-routed app's route lives in the fragment.
        (uri.hasFragment ? '#${uri.fragment}' : '');
    setState(() => _sharing = true);
    final messenger = ToastMessenger.of(context);
    try {
      final shared = await widget.api.toolsShareOn(
        device,
        [port],
        path: path,
        secure: uri.scheme == 'https',
      );
      // The clicked port, path and scheme: an earlier share of the port may
      // hold it beside another page, at another path.
      final key =
          [
            for (final held in shared.share.ports)
              if (held.port == port) held.key,
          ].firstOrNull ??
          shared.share.firstKey;
      final container = _container;
      if (!mounted || key == null || container == null) return;
      await openShareWith(
        context,
        container.read,
        ShareRef(
          service: key,
          path: path,
          title: shared.share.title,
          secure: uri.scheme == 'https',
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      messenger.error(friendlyError(error));
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    var local = false;
    try {
      final key = widget.serviceKey;
      local = key == null || await widget.api.metaHostIsLocal(key);
    } catch (_) {
      /* Unverified hosts stay remote. */
    }
    if (!mounted) return;
    if (local) {
      await openWebUrl(context, widget.url);
      if (mounted) Navigator.of(context).pop();
    } else {
      setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.fileLinkRemoteWebTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(widget.url),
            const SizedBox(height: 16),
            if (_checking) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(l10n.fileLinkCheckingHost),
            ] else
              Text(l10n.fileLinkRemoteWeb),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: widget.url)),
          child: Text(l10n.copy),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.fileLinkClose),
        ),
        if (_sharingDevice case final device? when !_checking)
          FilledButton(
            key: const Key('host-link-share-open'),
            onPressed: _sharing ? null : () => _shareAndOpen(device),
            child: Text(_sharing ? l10n.toolsSharing : l10n.toolsShareAndOpen),
          ),
      ],
    );
  }
}

class _FileLinkDialog extends StatefulWidget {
  const _FileLinkDialog({
    required this.api,
    required this.serviceKey,
    required this.threadId,
    required this.link,
  });
  final BridgeApi api;
  final String? serviceKey;
  final String? threadId;
  final FileLink link;
  @override
  State<_FileLinkDialog> createState() => _FileLinkDialogState();
}

class _FileLinkDialogState extends State<_FileLinkDialog> {
  bool _busy = false;
  String? _error;
  FilePreviewData? _preview;
  Future<bool>? _local;
  bool _retryDownload = false;
  Future<bool> _isLocal() => _local ??= widget.serviceKey == null
      ? Future.value(true)
      : widget.api.metaHostIsLocal(widget.serviceKey!).catchError((_) => false);

  Future<void> _run(bool download) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _retryDownload = download;
    });
    final l10n = AppLocalizations.of(context);
    final messenger = ToastMessenger.of(context);
    Directory? staging;
    try {
      final local = await _isLocal();
      if (!mounted) return;
      if (download) {
        String source;
        if (local) {
          source = widget.link.path;
        } else {
          staging = await Directory.systemTemp.createTemp('pcx-download-');
          source = '${staging.path}/content';
          await widget.api.metaFileDownload(
            widget.serviceKey!,
            widget.threadId,
            widget.link.href,
            source,
          );
        }
        if (!mounted) return;
        final saved = await exportFile(source, widget.link.name);
        if (saved != null) messenger.ok(l10n.fileDownloaded(saved));
      } else {
        FilePreviewData preview;
        if (local) {
          final file = await File(widget.link.path).open();
          try {
            final size = await file.length();
            preview = FilePreviewData(
              bytes: await file.read(math.min(size, _previewLimit)),
              totalSize: size,
            );
          } finally {
            await file.close();
          }
        } else {
          preview = await widget.api.metaFilePreview(
            widget.serviceKey!,
            widget.threadId,
            widget.link.href,
          );
        }
        if (mounted) setState(() => _preview = preview);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '${l10n.fileLinkFailed}\n$error');
    } finally {
      try {
        await staging?.delete(recursive: true);
      } catch (_) {
        /* The OS may have removed temporary files. */
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _content(FilePreviewData preview) {
    // The text limit is for decoding only: a complete picture past it is
    // still complete, and must still be drawn.
    final textTruncated =
        preview.truncated || preview.bytes.length > _textLimit;
    String? text;
    try {
      text = utf8.decode(
        preview.bytes.take(_textLimit).toList(),
        allowMalformed: textTruncated,
      );
    } on FormatException {
      text = null;
    }
    return FilePreview(
      name: widget.link.name,
      // Images and SVGs decode from what was read; a truncated one is
      // refused by FilePreview rather than drawn half.
      bytes: preview.bytes,
      text: text,
      truncated: preview.truncated,
      textTruncated: textTruncated,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(
        widget.link.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                // Less on a short screen (a phone in landscape), so the
                // preview below keeps room; the path scrolls.
                constraints: BoxConstraints(
                  maxHeight: math.min(
                    96,
                    MediaQuery.sizeOf(context).height * 0.15,
                  ),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(widget.link.path),
                ),
              ),
              const SizedBox(height: 12),
              if (_busy) ...[
                const LinearProgressIndicator(),
                Text(l10n.fileLinkLoading),
              ],
              if (_error != null) ...[
                Text(_error!),
                TextButton(
                  onPressed: _busy ? null : () => _run(_retryDownload),
                  child: Text(l10n.retry),
                ),
              ],
              if (_preview case final preview?)
                SizedBox(
                  height: math.min(
                    480,
                    MediaQuery.sizeOf(context).height * 0.45,
                  ),
                  child: _content(preview),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.fileLinkClose),
        ),
        TextButton(
          onPressed: _busy ? null : () => _run(false),
          child: Text(l10n.fileLinkPreview),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : () => _run(true),
          icon: const Icon(AppIcons.download),
          label: Text(l10n.fileLinkDownload),
        ),
      ],
    );
  }
}
