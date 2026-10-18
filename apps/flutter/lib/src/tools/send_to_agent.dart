/// Send what the user sees in a shared page back to the agent that shared
/// it: the page's address and its recent console errors join that
/// conversation's draft. Nothing is sent by itself.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/service_key.dart';
import 'package:pocket_codex/src/tools/tools_providers.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';

/// The conversation service of the harness behind a share's owner.
String? conversationService(String device, String? harness, String? host) {
  if (host == null || host.isEmpty || device.isEmpty) return null;
  final kind = switch (harness) {
    'codex' => 'app',
    'opencode' => 'opencode',
    null || '' => null,
    _ => 'acp',
  };
  return kind == null ? null : 'pcx:$device:$kind:$host';
}

/// The note added to the draft.
String previewNote({
  required String title,
  required String url,
  required String device,
  required List<String> console,
}) {
  final buffer = StringBuffer(
    'Preview of "$title" ($url, shared from $device)',
  );
  if (console.isEmpty) {
    buffer.write(': no console errors.');
  } else {
    buffer
      ..writeln(', recent console messages:')
      ..writeln('```')
      ..writeln(console.join('\n'))
      ..write('```');
  }
  return buffer.toString();
}

/// Add the preview of share [serviceKey] to its agent's conversation draft
/// and go back there; without a known conversation the note is copied.
Future<void> sendPreviewToAgent(
  BuildContext context,
  WidgetRef ref, {
  required String? serviceKey,
  required String title,
  required String url,
  required List<String> console,
}) async {
  final l10n = AppLocalizations.of(context);
  final overview = ref.read(toolsOverviewProvider);
  final live = serviceKey == null ? null : overview.shareOfKey(serviceKey);
  final device = serviceKey == null ? '' : parseServiceKey(serviceKey).device;
  final note = previewNote(
    title: title,
    url: url,
    device: device,
    console: console,
  );
  final owner = live?.share.owner;
  final service = conversationService(device, owner?.harness, owner?.host);
  final thread = owner?.conversation;
  if (service == null || thread == null) {
    await Clipboard.setData(ClipboardData(text: note));
    if (context.mounted) showToastOk(context, l10n.copied);
    return;
  }
  addToConversationDraft(ref, service, thread, note);
  if (!context.mounted) return;
  showToastOk(context, l10n.browserSentToDraft);
  context.pop();
}
