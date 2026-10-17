/// The chat screen: sending turns, rendering the transcript, the composer, and
/// the panes and pickers around them.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart'
    as fsel;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/attachment_refs.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/image_attachments.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/app_session/activity_cards.dart';
import 'package:pocket_codex/src/screens/app_session/generated_image_card.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/widgets/markdown_view.dart';
import 'package:pocket_codex/src/widgets/message_images.dart';
import 'package:pocket_codex/src/widgets/status_dots.dart';
import 'package:pocket_codex/src/widgets/turn_minimap.dart';
import 'package:pocket_codex/src/widgets/middle_click_scroll.dart';
import 'package:pocket_codex/src/widgets/history_arrival.dart';

import '../fake_bridge_api.dart';
import '../support/screen_harness.dart';
import 'package:pocket_codex/src/app_icons.dart';

part 'app_session/activity_view.dart';
part 'app_session/attachments.dart';
part 'app_session/chrome.dart';
part 'app_session/connection.dart';
part 'app_session/history_paging.dart';
part 'app_session/monitoring.dart';
part 'app_session/plan_mode.dart';
part 'app_session/sidebar.dart';
part 'app_session/transcript.dart';
part 'app_session/turn_settings.dart';
part 'app_session/turns.dart';
part 'app_session/work.dart';

/// A project's heading in the sidebar (a new conversation also names its
/// project).
Finder projectHeading(String path, String name) => find.descendant(
  of: find.byKey(Key('project-header-$path')),
  matching: find.text(name),
);

void main() {
  // AppSessionScreen keeps per-thread plan/effort memory in process-wide static
  // maps (so a reopened thread restores its mode before the persisted config
  // lands). Reset it between tests so memory from one test can't leak into
  // another that reuses a thread id.
  setUp(AppSessionScreen.debugResetThreadMemory);

  _registerTurns();
  _registerAttachments();
  _registerTranscript();
  _registerWork();
  _registerPlanMode();
  _registerTurnSettings();
  _registerSidebar();
  _registerActivityView();
  _registerChrome();
  _registerConnection();
  _registerMonitoring();
  _registerHistoryPaging();
}
