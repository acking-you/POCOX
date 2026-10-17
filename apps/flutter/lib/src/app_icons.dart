/// The app's icon vocabulary.
///
/// One stroke family (Lucide) for every glyph the UI draws, so a toolbar, a
/// sidebar row and a status card all speak the same visual language. Every
/// glyph uses Lucide's 300 weight (a 1.55 stroke on its 24 grid instead of
/// 2): at the 14-20 px the UI draws them, the default reads heavier than the
/// text beside it. Names keep the Material identifiers they replaced, which
/// keeps call sites readable; the value is what the design picked. Solid
/// shapes that only read as filled (a status dot, the stop square) stay
/// Material glyphs.
// ignore_for_file: constant_identifier_names
library;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Icon constants used across the app.
abstract final class AppIcons {
  /// `account_circle_outlined`.
  static const IconData account_circle_outlined =
      LucideIcons.circleUserRound300;

  /// `account_tree_outlined`.
  static const IconData account_tree_outlined = LucideIcons.gitFork300;

  /// `add`.
  static const IconData add = LucideIcons.plus300;

  /// `add_photo_alternate_outlined`.
  static const IconData add_photo_alternate_outlined = LucideIcons.imagePlus300;

  /// `add_rounded`.
  static const IconData add_rounded = LucideIcons.plus300;

  /// `arrow_back`.
  static const IconData arrow_back = LucideIcons.arrowLeft300Dir;

  /// `arrow_downward`.
  static const IconData arrow_downward = LucideIcons.arrowDown300;

  /// `arrow_forward`.
  static const IconData arrow_forward = LucideIcons.arrowRight300Dir;

  /// `arrow_upward`.
  static const IconData arrow_upward = LucideIcons.arrowUp300;

  /// `arrow_upward_rounded`.
  static const IconData arrow_upward_rounded = LucideIcons.arrowUp300;

  /// `article_outlined`.
  static const IconData article_outlined = LucideIcons.logs300;

  /// `attach_file`.
  static const IconData attach_file = LucideIcons.paperclip300;

  /// `auto_awesome`.
  static const IconData auto_awesome = LucideIcons.sparkles300;

  /// `auto_awesome_outlined`.
  static const IconData auto_awesome_outlined = LucideIcons.sparkles300;

  /// `autorenew`.
  static const IconData autorenew = LucideIcons.refreshCw300;

  /// `battery_0_bar`.
  static const IconData battery_0_bar = LucideIcons.batteryWarning300;

  /// `battery_2_bar`.
  static const IconData battery_2_bar = LucideIcons.batteryLow300;

  /// `battery_3_bar`.
  static const IconData battery_3_bar = LucideIcons.batteryMedium300;

  /// `battery_4_bar`.
  static const IconData battery_4_bar = LucideIcons.batteryMedium300;

  /// `battery_5_bar`.
  static const IconData battery_5_bar = LucideIcons.batteryFull300;

  /// `battery_full`.
  static const IconData battery_full = LucideIcons.batteryFull300;

  /// `block`.
  static const IconData block = LucideIcons.ban300;

  /// `bolt`.
  static const IconData bolt = LucideIcons.zap300;

  /// `bolt_outlined`.
  static const IconData bolt_outlined = LucideIcons.zap300;

  /// `brightness_6_outlined`.
  static const IconData brightness_6_outlined = LucideIcons.sunMoon300;

  /// `brightness_auto_outlined`.
  static const IconData brightness_auto_outlined = LucideIcons.sunMoon300;

  /// `broken_image_outlined`.
  static const IconData broken_image_outlined = LucideIcons.imageOff300;

  /// `call_end`.
  static const IconData call_end = LucideIcons.phoneOff300;

  /// `call_end_rounded`.
  static const IconData call_end_rounded = LucideIcons.phoneOff300;

  /// `chat_bubble_outline`.
  static const IconData chat_bubble_outline = LucideIcons.messageCircle300;

  /// `chat_bubble_outline_rounded`.
  static const IconData chat_bubble_outline_rounded =
      LucideIcons.messageCircle300;

  /// `check`.
  static const IconData check = LucideIcons.check300;

  /// `check_box`.
  static const IconData check_box = LucideIcons.squareCheck300;

  /// `check_box_outline_blank`.
  static const IconData check_box_outline_blank = LucideIcons.square300;

  /// `check_circle`.
  static const IconData check_circle = LucideIcons.circleCheck300;

  /// `check_circle_outline`.
  static const IconData check_circle_outline = LucideIcons.circleCheck300;

  /// `check_circle_rounded`.
  static const IconData check_circle_rounded = LucideIcons.circleCheck300;

  /// `check_rounded`.
  static const IconData check_rounded = LucideIcons.check300;

  /// `checklist`.
  static const IconData checklist = LucideIcons.listChecks300;

  /// `checklist_rounded`.
  static const IconData checklist_rounded = LucideIcons.listChecks300;

  /// `checklist_rtl`.
  static const IconData checklist_rtl = LucideIcons.listChecks300;

  /// `chevron_left`.
  static const IconData chevron_left = LucideIcons.chevronLeft300Dir;

  /// `chevron_left_rounded`.
  static const IconData chevron_left_rounded = LucideIcons.chevronLeft300Dir;

  /// `chevron_right`.
  static const IconData chevron_right = LucideIcons.chevronRight300Dir;

  /// `circle`.
  static const IconData circle = Icons.circle;

  /// `circle_outlined`.
  static const IconData circle_outlined = LucideIcons.circle300;

  /// `cleaning_services_outlined`.
  static const IconData cleaning_services_outlined =
      LucideIcons.brushCleaning300;

  /// `clear`.
  static const IconData clear = LucideIcons.x300;

  /// `clear_all`.
  static const IconData clear_all = LucideIcons.listX300;

  /// `close`.
  static const IconData close = LucideIcons.x300;

  /// `close_rounded`.
  static const IconData close_rounded = LucideIcons.x300;

  /// `cloud_off`.
  static const IconData cloud_off = LucideIcons.cloudOff300;

  /// `cloud_off_outlined`.
  static const IconData cloud_off_outlined = LucideIcons.cloudOff300;

  /// `compress`.
  static const IconData compress = LucideIcons.foldVertical300;

  /// `computer`.
  static const IconData computer = LucideIcons.monitor300;

  /// `computer_outlined`.
  static const IconData computer_outlined = LucideIcons.monitor300;

  /// `construction_rounded`.
  static const IconData construction_rounded = LucideIcons.waypoints300;

  /// `content_copy_outlined`.
  static const IconData content_copy_outlined = LucideIcons.copy300;

  /// `content_cut`.
  static const IconData content_cut = LucideIcons.scissors300;

  /// `copy`.
  static const IconData copy = LucideIcons.copy300;

  /// `copy_all_outlined`.
  static const IconData copy_all_outlined = LucideIcons.copy300;

  /// `copy_outlined`.
  static const IconData copy_outlined = LucideIcons.copy300;

  /// `create_new_folder_outlined`.
  static const IconData create_new_folder_outlined = LucideIcons.folderPlus300;

  /// `crop_square`.
  static const IconData crop_square = LucideIcons.square300;

  /// `dark_mode_outlined`.
  static const IconData dark_mode_outlined = LucideIcons.moon300;

  /// `data_usage`.
  static const IconData data_usage = LucideIcons.chartPie300;

  /// `description_outlined`.
  static const IconData description_outlined = LucideIcons.fileText300;

  /// `devices_other_outlined`.
  static const IconData devices_other_outlined =
      LucideIcons.monitorSmartphone300;

  /// `devices_outlined`.
  static const IconData devices_outlined = LucideIcons.monitorSmartphone300;

  /// `difference`: changes, shown as a document with what was added and
  /// taken out of it.
  static const IconData difference = LucideIcons.fileDiff300;

  /// `difference_outlined`.
  static const IconData difference_outlined = LucideIcons.fileDiff300;

  /// A changed file in the review.
  static const IconData file_diff = LucideIcons.fileDiff300;

  /// A file the change created.
  static const IconData file_plus = LucideIcons.filePlus300;

  /// A file the change deleted.
  static const IconData file_minus = LucideIcons.fileMinus300;

  /// A file read whole, as source.
  static const IconData file_code = LucideIcons.fileCode300;

  /// `dns_outlined`.
  static const IconData dns_outlined = LucideIcons.server300;

  /// `download`.
  static const IconData download = LucideIcons.download300;

  /// `download_outlined`.
  static const IconData download_outlined = LucideIcons.download300;

  /// `download_rounded`.
  static const IconData download_rounded = LucideIcons.download300;

  /// `downloading`.
  static const IconData downloading = LucideIcons.cloudDownload300;

  /// `drive_file_move_outline`.
  static const IconData drive_file_move_outline = LucideIcons.folderInput300;

  /// `edit`.
  static const IconData edit = LucideIcons.pencil300;

  /// `edit_document`.
  static const IconData edit_document = LucideIcons.filePen300;

  /// `edit_location_alt_outlined`.
  static const IconData edit_location_alt_outlined = LucideIcons.mapPinPen300;

  /// `edit_outlined`.
  static const IconData edit_outlined = LucideIcons.pencil300;

  /// `edit_square`.
  static const IconData edit_square = LucideIcons.squarePen300;

  /// `error_outline`.
  static const IconData error_outline = LucideIcons.circleAlert300;

  /// `expand_less`.
  static const IconData expand_less = LucideIcons.chevronUp300;

  /// `expand_less_rounded`.
  static const IconData expand_less_rounded = LucideIcons.chevronUp300;

  /// `expand_more`.
  static const IconData expand_more = LucideIcons.chevronDown300;

  /// `expand_more_rounded`.
  static const IconData expand_more_rounded = LucideIcons.chevronDown300;

  /// `extension`.
  static const IconData extension = LucideIcons.puzzle300;

  /// `fact_check_outlined`.
  static const IconData fact_check_outlined = LucideIcons.clipboardCheck300;

  /// `file_download_outlined`.
  static const IconData file_download_outlined = LucideIcons.fileDown300;

  /// `filter_none`.
  static const IconData filter_none = LucideIcons.copy300;

  /// `folder_off_outlined`.
  static const IconData folder_off_outlined = LucideIcons.folderX300;

  /// `folder_open`.
  static const IconData folder_open = LucideIcons.folderOpen300;

  /// `folder_open_outlined`.
  static const IconData folder_open_outlined = LucideIcons.folderOpen300;

  /// `folder_outlined`.
  static const IconData folder_outlined = LucideIcons.folder300;

  /// `folder_shared_outlined`.
  static const IconData folder_shared_outlined = LucideIcons.folderGit2300;

  /// `folder_special_outlined`.
  static const IconData folder_special_outlined = LucideIcons.folderHeart300;

  /// `format_list_numbered`.
  static const IconData format_list_numbered = LucideIcons.tableOfContents300;

  /// `forum_outlined`.
  static const IconData forum_outlined = LucideIcons.messagesSquare300;

  /// `gpp_bad_outlined`.
  static const IconData gpp_bad_outlined = LucideIcons.shieldX300;

  /// `graphic_eq`.
  static const IconData graphic_eq = LucideIcons.audioLines300;

  /// `groups_outlined`.
  static const IconData groups_outlined = LucideIcons.users300;

  /// `help_outline`.
  static const IconData help_outline = LucideIcons.circleHelp300;

  /// `history`.
  static const IconData history = LucideIcons.history300;

  /// `history_outlined`.
  static const IconData history_outlined = LucideIcons.history300;

  /// `history_rounded`.
  static const IconData history_rounded = LucideIcons.history300;

  /// `history_toggle_off`.
  static const IconData history_toggle_off = LucideIcons.clockFading300;

  /// `hourglass_empty`.
  static const IconData hourglass_empty = LucideIcons.hourglass300;

  /// `image_outlined`.
  static const IconData image_outlined = LucideIcons.image300;

  /// `image_search_outlined`.
  static const IconData image_search_outlined = LucideIcons.imageUp300;

  /// `info_outline`.
  static const IconData info_outline = LucideIcons.info300;

  /// `insert_drive_file_outlined`.
  static const IconData insert_drive_file_outlined = LucideIcons.file300;

  /// `inventory_2_outlined`.
  static const IconData inventory_2_outlined = LucideIcons.archive300;

  /// `ios_share_outlined`.
  static const IconData ios_share_outlined = LucideIcons.share300;

  /// `key_outlined`.
  static const IconData key_outlined = LucideIcons.keyRound300;

  /// `keyboard_arrow_down`.
  static const IconData keyboard_arrow_down = LucideIcons.chevronDown300;

  /// `keyboard_arrow_down_rounded`.
  static const IconData keyboard_arrow_down_rounded =
      LucideIcons.chevronDown300;

  /// `keyboard_arrow_right`.
  static const IconData keyboard_arrow_right = LucideIcons.chevronRight300Dir;

  /// `keyboard_arrow_right_rounded`.
  static const IconData keyboard_arrow_right_rounded =
      LucideIcons.chevronRight300Dir;

  /// `keyboard_arrow_up`.
  static const IconData keyboard_arrow_up = LucideIcons.chevronUp300;

  /// `keyboard_arrow_up_rounded`.
  static const IconData keyboard_arrow_up_rounded = LucideIcons.chevronUp300;

  /// `lan_outlined`.
  static const IconData lan_outlined = LucideIcons.network300;

  /// `language`.
  static const IconData language = LucideIcons.globe300;

  /// `layers_outlined`.
  static const IconData layers_outlined = LucideIcons.layers300;

  /// `light_mode_outlined`.
  static const IconData light_mode_outlined = LucideIcons.sun300;

  /// `lightbulb_outline`.
  static const IconData lightbulb_outline = LucideIcons.lightbulb300;

  /// `link_off_outlined`.
  static const IconData link_off_outlined = LucideIcons.unlink300;

  /// `link_outlined`.
  static const IconData link_outlined = LucideIcons.link300;

  /// `lock_clock`.
  static const IconData lock_clock = LucideIcons.lockKeyhole300;

  /// `lock_clock_outlined`.
  static const IconData lock_clock_outlined = LucideIcons.lockKeyhole300;

  /// `lock_open`.
  static const IconData lock_open = LucideIcons.lockOpen300;

  /// `lock_open_outlined`.
  static const IconData lock_open_outlined = LucideIcons.lockOpen300;

  /// `lock_outline`.
  static const IconData lock_outline = LucideIcons.lock300;

  /// `login`.
  static const IconData login = LucideIcons.logIn300;

  /// `logout`.
  static const IconData logout = LucideIcons.logOut300;

  /// `menu`.
  static const IconData menu = LucideIcons.menu300;

  /// `mic`.
  static const IconData mic = LucideIcons.mic300;

  /// `mic_none_rounded`.
  static const IconData mic_none_rounded = LucideIcons.mic300;

  /// `mic_off`.
  static const IconData mic_off = LucideIcons.micOff300;

  /// `mic_off_rounded`.
  static const IconData mic_off_rounded = LucideIcons.micOff300;

  /// `more_horiz`.
  static const IconData more_horiz = LucideIcons.ellipsis300;

  /// `my_location_rounded`.
  static const IconData my_location_rounded = LucideIcons.locateFixed300;

  /// `open_in_full`.
  static const IconData open_in_full = LucideIcons.maximize2300;

  /// `open_in_new`.
  static const IconData open_in_new = LucideIcons.externalLink300;

  /// `output_rounded`.
  static const IconData output_rounded = LucideIcons.logOut300;

  /// `pause`.
  static const IconData pause = LucideIcons.pause300;

  /// `person_outline`.
  static const IconData person_outline = LucideIcons.user300;

  /// Opening a hidden sidebar (its close control is `view_sidebar_outlined`).
  static const IconData panel_left_open = LucideIcons.panelLeftOpen300;

  /// Closing the review panel on the right.
  static const IconData panel_right_close = LucideIcons.panelRightClose300;

  /// Opening the review panel on the right.
  static const IconData panel_right_open = LucideIcons.panelRightOpen300;

  /// `pin_outlined`.
  static const IconData pin_outlined = LucideIcons.pin300;

  /// `play_arrow`.
  static const IconData play_arrow = LucideIcons.play300;

  /// `play_arrow_rounded`.
  static const IconData play_arrow_rounded = LucideIcons.play300;

  /// `play_circle_outline`.
  static const IconData play_circle_outline = LucideIcons.circlePlay300;

  /// `playlist_add`.
  static const IconData playlist_add = LucideIcons.listPlus300;

  /// `policy_outlined`.
  static const IconData policy_outlined = LucideIcons.shieldCheck300;

  /// `power_settings_new`.
  static const IconData power_settings_new = LucideIcons.power300;

  /// `psychology_outlined`.
  static const IconData psychology_outlined = LucideIcons.brain300;

  /// `public`.
  static const IconData public = LucideIcons.globe300;

  /// `radio_button_unchecked`.
  static const IconData radio_button_unchecked = LucideIcons.circle300;

  /// `refresh`.
  static const IconData refresh = LucideIcons.refreshCw300;

  /// `refresh_rounded`.
  static const IconData refresh_rounded = LucideIcons.refreshCw300;

  /// `remove`.
  static const IconData remove = LucideIcons.minus300;

  /// `restart_alt`.
  static const IconData restart_alt = LucideIcons.rotateCcw300;

  /// `rocket_launch_outlined`.
  static const IconData rocket_launch_outlined = LucideIcons.rocket300;

  /// `schedule`.
  static const IconData schedule = LucideIcons.clock300;

  /// `search`.
  static const IconData search = LucideIcons.search300;

  /// `search_off`.
  static const IconData search_off = LucideIcons.searchX300;

  /// `settings`.
  static const IconData settings = LucideIcons.settings300;

  /// `settings_outlined`.
  static const IconData settings_outlined = LucideIcons.settings300;

  /// `shield_outlined`.
  static const IconData shield_outlined = LucideIcons.shield300;

  /// `source_outlined`.
  static const IconData source_outlined = LucideIcons.fileCode300;

  /// `speed`.
  static const IconData speed = LucideIcons.gauge300;

  /// `star_outline`.
  static const IconData star_outline = LucideIcons.star300;

  /// `stop_circle_outlined`.
  static const IconData stop_circle_outlined = LucideIcons.circleStop300;

  /// `stop_rounded`.
  static const IconData stop_rounded = Icons.stop_rounded;

  /// `storage_outlined`.
  static const IconData storage_outlined = LucideIcons.database300;

  /// `subdirectory_arrow_left`.
  static const IconData subdirectory_arrow_left =
      LucideIcons.cornerDownLeft300Dir;

  /// `swap_horiz`.
  static const IconData swap_horiz = LucideIcons.arrowLeftRight300;

  /// `sync`.
  static const IconData sync = LucideIcons.refreshCw300;

  /// `sync_problem`.
  static const IconData sync_problem = LucideIcons.refreshCwOff300;

  /// `sync_rounded`.
  static const IconData sync_rounded = LucideIcons.refreshCw300;

  /// `terminal`.
  static const IconData terminal = LucideIcons.squareTerminal300;

  /// `terminal_rounded`.
  static const IconData terminal_rounded = LucideIcons.squareTerminal300;

  /// `text_snippet_outlined`.
  static const IconData text_snippet_outlined = LucideIcons.fileText300;

  /// `timelapse_rounded`.
  static const IconData timelapse_rounded = LucideIcons.loaderCircle300;

  /// `travel_explore`.
  static const IconData travel_explore = LucideIcons.globe300;

  /// `tune`.
  static const IconData tune = LucideIcons.slidersHorizontal300;

  /// `unfold_less`.
  static const IconData unfold_less = LucideIcons.chevronsDownUp300;

  /// `unfold_more`.
  static const IconData unfold_more = LucideIcons.chevronsUpDown300;

  /// `unfold_more_rounded`.
  static const IconData unfold_more_rounded = LucideIcons.chevronsUpDown300;

  /// `upload_file`.
  static const IconData upload_file = LucideIcons.fileUp300;

  /// `verified_outlined`.
  static const IconData verified_outlined = LucideIcons.badgeCheck300;

  /// `verified_user_outlined`.
  static const IconData verified_user_outlined = LucideIcons.shieldCheck300;

  /// `vertical_align_bottom`.
  static const IconData vertical_align_bottom = LucideIcons.arrowDownToLine300;

  /// `view_sidebar_outlined`.
  static const IconData view_sidebar_outlined = LucideIcons.panelLeftClose300;

  /// `vpn_key_outlined`.
  static const IconData vpn_key_outlined = LucideIcons.keyRound300;

  /// `warning_amber_rounded`.
  static const IconData warning_amber_rounded = LucideIcons.triangleAlert300;

  /// `webhook_outlined`.
  static const IconData webhook_outlined = LucideIcons.webhook300;
}
