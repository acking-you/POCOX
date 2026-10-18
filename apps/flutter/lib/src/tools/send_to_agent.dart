/// Send what the user sees in a shared page back to the agent that shared
/// it: the page's address and its recent console errors join that
/// conversation's draft. Nothing is sent by itself.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/service_key.dart';
import 'package:pocket_codex/src/tools/tools_providers.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';

/// The conversation service of the harness behind the owner of the share
/// keyed [shareKey]: on the same device, in the same namespace (`pcx:` or an
/// account's `pcxu:<user>:`).
String? conversationService(String shareKey, String? harness, String? host) {
  final parsed = parseServiceKey(shareKey);
  if (host == null || host.isEmpty || parsed.device.isEmpty) return null;
  final kind = switch (harness) {
    'codex' => 'app',
    'opencode' => 'opencode',
    null || '' => null,
    _ => 'acp',
  };
  if (kind == null) return null;
  final tail = ':${parsed.kind}:${parsed.name}';
  return '${shareKey.substring(0, shareKey.length - tail.length)}:$kind:$host';
}

/// [url] as the sharing computer reaches it: on the share's own port, which
/// this device may have had to replace with another.
String sharedPageUrl(String url, String? serviceKey) {
  final port = serviceKey == null
      ? null
      : int.tryParse(parseServiceKey(serviceKey).name);
  final uri = Uri.tryParse(url);
  if (port == null || uri == null || !uri.hasAuthority) return url;
  return uri.replace(port: port).toString();
}

/// The note added to the draft, in the user's language; [failure] is why
/// the page did not load, when it did not.
String previewNote(
  AppLocalizations l10n, {
  required String title,
  required String url,
  required String device,
  required List<String> console,
  String? failure,
}) {
  final head = failure != null
      ? l10n.browserNoteFailed(title, url, device, failure)
      : console.isEmpty
      ? l10n.browserNoteNoErrors(title, url, device)
      : l10n.browserNoteConsole(title, url, device);
  if (console.isEmpty) return head;
  return [head, '```', ...console, '```'].join('\n');
}

/// Add the preview of share [serviceKey] to its agent's conversation draft
/// and open that conversation (unless it is the page under the preview);
/// without a known conversation the note is copied. [failure] says why the
/// page did not load, when it did not.
Future<void> sendPreviewToAgent(
  BuildContext context,
  WidgetRef ref, {
  required String? serviceKey,
  required String title,
  required String url,
  required List<String> console,
  String? failure,
}) async {
  final l10n = AppLocalizations.of(context);
  final overview = ref.read(toolsOverviewProvider);
  final live = serviceKey == null ? null : overview.shareOfKey(serviceKey);
  final device = serviceKey == null ? '' : parseServiceKey(serviceKey).device;
  final note = previewNote(
    l10n,
    title: title,
    url: sharedPageUrl(url, serviceKey),
    device: deviceLabel(device),
    console: console,
    failure: failure,
  );
  final owner = live?.share.owner;
  final service = serviceKey == null
      ? null
      : conversationService(serviceKey, owner?.harness, owner?.host);
  final thread = owner?.conversation;
  if (service == null || thread == null) {
    await Clipboard.setData(ClipboardData(text: note));
    if (context.mounted) showToastOk(context, l10n.copied);
    return;
  }
  addToConversationDraft(ref, service, thread, note);
  if (!context.mounted) return;
  showToastOk(context, l10n.browserSentToDraft);
  final router = GoRouter.of(context);
  final target = Uri.parse(conversationRoute(service, thread));
  context.pop();
  final below = router.state.uri;
  if (below.path != target.path || below.queryParameters['tid'] != thread) {
    unawaited(router.push(target.toString()));
  }
}
