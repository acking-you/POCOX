import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';

export 'package:pocox/src/voice/voice_call_dock.dart';
export 'package:pocox/src/voice/voice_start_sheet.dart';

/// Canonical persisted speech history, loaded in bounded upstream pages.
class VoiceHistoryDialog extends StatefulWidget {
  const VoiceHistoryDialog({
    super.key,
    required this.api,
    required this.serviceKey,
    required this.threadId,
  });
  final BridgeApi api;
  final String serviceKey;
  final String threadId;
  @override
  State<VoiceHistoryDialog> createState() => _VoiceHistoryDialogState();
}

class _VoiceHistoryDialogState extends State<VoiceHistoryDialog> {
  final _entries = <Map<String, dynamic>>[];
  final _entryIds = <String>{};
  String? _cursor;
  bool _loading = false;
  bool _more = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading || !_more) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await widget.api.appRealtimeRequest(
        widget.serviceKey,
        'thread/timeline/list',
        jsonEncode({
          'threadId': widget.threadId,
          'limit': 100,
          if (_cursor != null) 'cursor': _cursor,
        }),
      );
      final page = jsonDecode(raw) as Map;
      if (!mounted) return;
      setState(() {
        for (final entry in page['data'] as List) {
          if (entry['type'] != 'realtime') continue;
          final item = Map<String, dynamic>.from(entry['item'] as Map);
          if (item['type'] == 'transcriptSegment' &&
              item['id'] is String &&
              _entryIds.add(item['id'] as String)) {
            _entries.add(item);
          }
        }
        _cursor = page['nextCursor'] as String?;
        _more = _cursor != null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.voiceHistory),
      content: SizedBox(
        width: 560,
        height: MediaQuery.sizeOf(context).height * .55,
        child: ListView.builder(
          itemCount: _entries.length + 1,
          itemBuilder: (context, index) {
            if (index < _entries.length) {
              final item = _entries[index];
              return ListTile(
                title: Text(item['role'] == 'user' ? l.voiceYou : l.voiceAgent),
                subtitle: SelectableText(item['text'] as String? ?? ''),
              );
            }
            return Column(
              children: [
                if (_entries.isEmpty && !_loading && _error == null)
                  Text(l.voiceHistoryEmpty),
                if (_error != null) Text(_error!),
                if (_loading)
                  const LinearProgressIndicator()
                else if (_more)
                  TextButton(
                    onPressed: _load,
                    child: Text(_error == null ? l.voiceHistoryMore : l.retry),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }
}
