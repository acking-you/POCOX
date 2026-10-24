# Flutter app UI

This document holds the durable design and behaviour rules of the Flutter app
in `apps/flutter`: the design system, phone/tablet/desktop layouts, the
transcript and review, the sidebar, forms and hosting feedback, fonts and the
generated brand art. Shared styling lives in `apps/flutter/lib/src/theme.dart`
and `desktop_theme.dart`, widgets in `lib/src/widgets/`, the conversation
screen in `lib/src/screens/app_session/`, the review in `lib/src/review/` and
the hosting editor in `lib/src/hosting/`. Drafts, sending and queueing are in
[Composer, drafts and turns](composer-turns.md); history paging, caching and
monitoring are in [Controller history cache](session-cache-sync.md).

## Design system

Windows release/profile builds do not attach to a launcher's console. The GUI
must survive a terminal or update helper being closed; only debug builds attach
for Flutter diagnostics. Native console lifetime tests live in
`windows/runner/tests` and run in the Windows CI job.

- Shared colours, typography and control shapes live in `theme.dart` /
  `desktop_theme.dart`; secondary pages use `UtilityPage`
  (`widgets/utility_page.dart`).
- Palette: calm graphite neutrals, ink-black primary actions, the logo's blue
  as the one, sparse signal colour. No purple, no hue cast in greys or
  shadows, a backdrop lit only by white (multi-hue backdrops and iris accents
  proved tiring). The blue-and-white app icon is never recoloured.
- Icons are Lucide through `AppIcons` (`lib/src/app_icons.dart`).
- Desktop pages are layered (`widgets/glass.dart`, `lib/src/glass_recipe.dart`):
  navigation on a lit neutral backdrop (`AppBackdrop`), content on an inset
  rounded sheet (`ContentSheet`), floating controls (composer, navigation
  cluster, toasts, minimap, turn progress) as translucent `Glass` (`GlassDepth`
  chrome / floating / overlay: lit rim, blur, outer-only shadows). The
  transcript scrolls beneath the composer.
- The macOS title strip is 60 pt (`titleStripHeight` in
  `macos/Runner/MainFlutterWindow.swift`, `WindowChrome.barHeight` in
  `widgets/window_title_bar.dart`), traffic lights centred on the sheet bars.
- Modals use `showAppDialog` (`widgets/app_dialog.dart`, blurred and dimmed
  backdrop); `fullscreen: true` for full-window editors, which keep their own
  safe areas.
- Pickers and information opened from a control are desktop popovers anchored
  to it (`widgets/popover.dart`; `showAdaptivePanel(anchored:)`,
  `showChoicePanel`, `showInfoPanel` in `widgets/adaptive_sheet.dart`) and
  bottom sheets on touch.
- An open option menu is bound to the conversation, load, capability and
  connection generation it opened for.
- Segmented choices use `GlassSegmented`; motion uses `Motion.spring` /
  `Motion.emphasized` (`lib/src/motion.dart`); desktop routes fade; lit buttons
  clip their sheen to the capsule (`LitFace`); theme switches spread from the
  pressed control (`lib/src/theme_transition.dart`).
- One mark per row: a hosted chat service is its host's row, project headings
  carry no folder glyph, composer context is text separated by dots. Dark-mode
  favicons sit on a light plate.
- Compact layouts need reachable touch targets and readable text, not a scaled
  desktop screenshot. Validate light and dark at phone, tablet and desktop
  widths.

## Home, connection and relay problems

- Settings › Connection path (`lib/src/network/connection_paths.dart`) is a
  `GroupCard` in both layouts: outgoing **Relay only / P2P first** as a
  `GlassSegmented` (under its title below 480 px) and, on desktop only, an
  incoming switch. Choices save at once, optimistically; a failed write springs
  the control back with a failed line. Its explanation sits behind the group's
  info mark; the visible line under a control is only pending ("reconnect a
  session", "restart hosting") or failed. Relay-only is the default and incoming
  direct is disabled; only an opt-in is written.
- How a connection travels has one visual language: in words, P2P direct /
  Via relay / Direct n · Relay m / Idle / Relay only (`tunnelPathLabel`), and
  after a state "Connected · P2P" or "Subscribed · Relay" (`ConnectedChip`,
  the services hub's app and API rows); in the galaxy, a bright taut beam for
  direct, a dashed high arc for the relay, both for mixed
  ([connection paths](galaxy-geometry.md#connection-paths)). A local host
  reached over loopback shows no path.
- Subscription rows carry one `TunnelPathChip` (live path or dropped) and open
  live details from the pressed row. Paths come from local SDK observations,
  never from the preference; the polled list is watched by the subscription
  widgets alone, so polling rebuilds them, not the settings page, and stops
  with the last view. See
  [direct connections](relay-worker-recovery.md#direct-connections).
- Recovery is shown as it happens ([watching a link
  recover](relay-worker-recovery.md#watching-a-link-recover)): the model is
  `network/link_activity.dart` (`linkWatchProvider` polls one service every
  400 ms while watched; `linkSteps` turns a tunnel, the connect stage and the
  controller's `ReconnectState` into relay / P2P / session steps), drawn by
  `widgets/link_progress.dart`: `LinkPipeline` (three nodes, the active one
  turning, a failed one saying why), `LinkDots` for a status line,
  `LinkTimeline` for recent events and `showLinkSheet`, a popover on desktop
  and a sheet on touch. A reconnecting session's status bar shows
  `LinkStatusLine` in place of its state and a `LinkPathMark` at all times; both
  open the sheet, whose **Retry now** ends the wait between attempts.

- `/` is chat-first: it resolves a host (last used → locally hosted → first
  reachable), auto-connects and opens the latest session with all sessions in
  the sidebar; the services hub is `/manage` (`lib/src/router.dart`). The home
  cross-fades between splash, hero and chat by phase.
- Onboarding takes relay + key (with `pcx1:` import/export) or an account and
  persists to `config.toml` (0600). Desktop restores hosting on boot from
  `ui_state.json` (`lib/src/ui_prefs.dart`).
- Connect to an in-app host through its registered loopback endpoint; never
  relay a device's own traffic or probe relay health to resolve it. Remote
  relay connections stay first-class.
- When the relay cannot list services, a desktop still restores its hosts and
  opens its own host over loopback (a toast says other devices cannot reach
  it). The services page keeps this computer's hosts under a relay problem
  card (`widgets/relay_problem.dart`: cause in words, retry, raw error folded
  and copyable), the relay marked unreachable and its tunnels not connected.
- A relay name resolving only to 198.18.0.0/15 is named as a proxy's or VPN's
  unrouted virtual address (`lib/src/relay_diagnosis.dart`). The app never
  resolves around the system DNS.

## Phone and tablet layout

- Below 720 px the sessions list lies under the conversation
  (`widgets/layered_navigation.dart`). A touch/stylus horizontal drag anywhere
  on the page, past touch slop, moves the page with the finger and rests where
  held; the page's own horizontal scrollables and text gestures win first.
- Release completes the direction the finger last clearly moved in, however
  short (a 16 px reversal flips it); no distance or velocity threshold. The
  open sidebar closes the same way.
- One light haptic when a gesture settles open; recognition, the menu control
  and closing drags are silent.
- Opening parks focus on the sidebar scope (`requestScopeFocus`), never its
  search field, so a swipe never raises the keyboard.
- The sidebar stays mounted offstage (scroll, folds, search kept; not rebuilt
  while hidden). The moved page keeps its state and leaves input, focus and
  semantics.
- Back and Escape close it first. A system pointer cancel returns the drag to
  its start with no completion haptic. Mouse drags and an open keyboard leave
  the page alone.
- Close it through `LayeredNavigation.maybeOf` (`isOpen` / `close`), never
  `Scaffold` drawers.
- Touch-only polish: tonal new-conversation pill, 14 px row/search radius,
  22 px composer radius with a quieter idle edge, 44 px sidebar heading
  buttons, two-line host switcher names.
- Below 720 px on touch the composer is a capsule whenever no one is writing
  (`_composerFolded` in `screens/app_session/composer_foot.dart`,
  `widgets/folding_panel.dart`): every conversation opens folded, and it
  unfolds only while the field has focus, a dictation take runs or the full
  editor is open. A tap on the capsule focuses the field; letting go folds it
  again. Reaching the end, jumping to the latest message, sending and a reply
  arriving leave it as it is. A keyboard put away while the field keeps focus
  (Android's back button) releases the field after 250 ms, unless it came back,
  another app is in front or a take runs. The capsule is the same glass pane
  (radius, focus and streaming edges) showing the draft's first line or the
  hint, attachments and Stop while a turn runs. Desktop, tablets and read-only
  views never fold. The full composer stays mounted underneath, so draft and
  options survive. The height morphs on the emphasized curve over
  `Motion.slow`, roughly with the keyboard; both forms fade on that eased
  progress (so the pane is never empty glass) and settle 6 px into place, and
  the focus lift eases over the same time.
- What floats over the transcript's foot is measured into a notifier
  (`_ComposerFoot.overlay`): its growth, drag and fold move only the end
  spacer and the overlays above it, never rebuild the conversation.
- Layouts reflow by measured room instead of squeezing:
  - Service capability rows below 440 px (text-scaled) put status and actions
    under the title and provider; the action keeps its overflow beside it.
  - Agent options, or a phone's Codex model chip, take a line above the
    attach/send row when their labels do not fit beside it (the model alone
    when sharing would halve a label), only while at least 420/520 px stay
    above the keyboard; otherwise they rejoin the toolbar and scroll. Option
    segments keep their state across moves. A Codex permission label that
    fits on neither line moves up beside the model.
  - Pending requests share the transcript's slot (each group at most 45 % of
    the screen, scrolling), so approve and send stay reachable.
  - On touch the chat pane and sidebar keep a minimum height and scroll in
    landscape or with the keyboard.
  - The status bar measures its line (`_statusFit`,
    `screens/app_session/session_status.dart`): the model name shortens, then
    the branch, then the model chip and clock give way; state and change
    counts always show. The link mark always shows, and the reconnect
    line's dots are reserved while reconnecting.
  - The narrow services device list scrolls, local session rows stack status
    and action under a narrow title, picker footers use `OverflowBar`.
- Every engine's new-conversation view (`screens/app_session/agent_welcome.dart`)
  uses the room above the composer: project identity centred (its mark dropped
  when short), other recent projects and Choose folder in one horizontal row
  just above the composer, mode chips such as Fast on the model's toolbar line.
  The Codex view shows the Codex mark like the other engines.
- Settings lists subscriptions by service key, never the internal composite
  identity.
- Touch tablets (720 px and wider) keep a 480 px chat and give the inline
  sidebar the rest (up to 520 px), so the default 280 px pane fits at 834 px;
  saved widths still apply. Touch rules do not change the desktop layout.

## Transcript

- One `CustomScrollView` around a centre row (`widgets/centered_scroll.dart`,
  `screens/app_session/transcript_list.dart`): rows above it lay out upward, so
  a page or gap filled above never moves what is on screen, and the end or a
  jumped-to turn is exact in the frame it becomes the centre. Layout holds the
  end (`stickToEnd`) until the reader scrolls, touches or selects. Never return
  to one index-keyed list or to post-frame anchor jumps. Paging side:
  [anchored transcript](session-cache-sync.md#anchored-transcript-2026-10-17).
- The in-flight history future is the only loading mark (`_historyLoad`;
  `_loadingOlder` derives from it and only its own completion clears it), so a
  throwing rebuild or immediate failure cannot strand "loading".
- Rows stay lazy and keyed; grouping must not rescan the rest of a turn per
  item. Pagination failures need an explicit retry, never a scroll-triggered
  request loop.
- Steering can split one turn into several work groups: show the total
  duration once and animate only the current active group. Missing duration
  is not evidence of a running turn.
- Long work lists use a bounded lazy viewport with explicit step ranges; never
  animate the height of hundreds of steps. Appends preserve the reader's
  selected range; a manually expanded group stays open when it finishes.
- Initial history shows a delayed static loading label: no mock shimmer, no
  overlapping outgoing/incoming transcripts. Supplementary loads keep content
  visible, with feedback only at the requested gap, top boundary or selected
  turn. Cancellation and new scroll intent beat late anchor restoration.
  Background tail updates stay quiet.
- Render initial history before optional saved configuration and model
  discovery finish; late metadata never overwrites a new user selection.
- Timeline selection jumps directly to the turn; only the latest selection may
  move the viewport, and prepend anchoring must not fight it.
- Sync and navigation status float over the transcript top
  (`widgets/floating_status.dart`) and fade in. The turn clock and sidebar
  motion do not rebuild the transcript.
- Minimap tick density is limited by available height (`widgets/turn_minimap.dart`);
  the exact active marker stays, and every turn is reachable through a lazy,
  searchable directory and the keyboard (`widgets/turn_outline.dart`). Narrow
  and touch layouts fold navigation into a faint `TurnNavigationHandle` (opens
  on touch, folds after 5 s or a scroll); wide desktops keep the rail.
- Above the latest message, the jump-to-latest button
  (`widgets/jump_to_latest_button.dart`) shows a blue moving ring while the
  conversation runs here or through a followed writer. Arrow and hit target
  stay still, the action returns to and follows the end, reduced motion keeps
  a steady ring, hidden or idle controls do not animate.
- User and agent messages render as Markdown; user messages keep typed line
  breaks.
- Mobile messages offer long-press copy, text selection and native sharing. A
  long-pressed message darkens by the neutral pressed layer in its own outline
  (`kUserBubbleShape` for user bubbles), no accent outline; its menu uses muted
  icons. Press timing: [touch feedback](live-voice.md#touch-feedback).
- Codex Desktop `<heartbeat>` automation prompts render as a capsule opening
  into their instructions (`lib/src/automation_prompt.dart`); blank replies
  leave no row.
- A user attachment whose temp file is gone is served from the rollout's inline
  copy (`crates/pocox-codex/src/rollout/inline_image.rs`). Host images are
  cached per host and thread, 64 MiB (`widgets/message_images.dart`).
- The read-only foot (takeover, read-only, Guardian, host access) is the
  composer's glass card over the same fade.

## Review

- `lib/src/review/` replaces the diff sheet: a resizable right sidebar from
  1100 px, an overlay panel below that, its own page on phones (back or swipe
  right).
- It shows this conversation's edits (every edit of a file in order, or one
  step from its change card) or the working tree against its upstream: lazy
  diffs, gap expansion, a whole-file view with changes marked.
- Files are read through `/fs/thread-file`; root-confined `/fs/read` only for
  older hosts. Diffs are parsed natively
  ([Rust offload](rust-offload.md#attachments-and-diff)).
- A working tree never read says so with a retry, never "no changes".

## Sidebar and session lists

- Selected conversations use neutral surfaces. Running rows combine a rotating
  indicator with a faint sweep (`widgets/running_sheen.dart`); reduced motion
  uses a static mark and label. Paint-only animation respects `TickerMode` and
  releases its controllers on disposal.
- Hierarchy controls keep keyboard/RTL semantics and 44 px touch targets. A
  row's fold control sits inside the row's plate (`SessionTreeRow.builder`
  receives the title inset), so a selected parent is one shape.
- Narrow sidebars and large text put metadata below titles.
- Project headings reveal one new-conversation action on hover or keyboard
  focus, with right-click menus and touch long-press sheets
  (`widgets/project_section_header.dart`).
- Until the host first lists its conversations, a delayed skeleton
  (`ConversationListSkeleton`, `widgets/loading.dart`) cross-fades into the
  list. The open conversation's own metadata is not a listing; exhausted
  retries end the skeleton.
- Codex Desktop managed worktrees
  (`<root>/worktrees/<4 hex>/<repository>[/<subfolder>]`) list under the
  checkout they came from (`ProjectIndex`, `lib/src/project_index.dart`),
  matched by repository name, subfolder and `gitInfo.originUrl`
  (`ThreadMeta.originUrl`). Without exactly one such checkout, a repository's
  worktrees share one project. A worktree row still opens in its own folder.

## Forms and hosting feedback

- Forms show names and values at rest: labels inside filled fields that are
  borderless until focused (`FieldBorder`, `widgets/glass.dart`); what a field
  is for appears under it only while focused (`FocusHelp`,
  `widgets/field_help.dart`); a section's or control's explanation sits behind
  an info mark (`InfoTip`, `InfoTitle`, `GroupCard.info`) or a tooltip.
- Visible lines under a control are state only (detected, taken, pending,
  failed), in `helpTextStyle`. Field errors wrap. Chinese strings use
  full-width punctuation.
- Hosting operations report on their own control: Start, Save, Restart and
  Stop become a spinner with what runs ("Starting…") in their working colours
  (`widgets/busy_label.dart`), and a running line crosses the action bar. The
  outcome is pinned above the actions, never at the end of the scrolled form.
  A finished start or stop closes the editor with one toast naming the host (a
  restore warning rides in it). Editor rules:
  [Hosting configuration](hosting-configuration.md).
- The Codex setup page (`screens/codex_setup_screen.dart`) lists ChatGPT
  sign-in and custom provider as two rows, each with its control at the row's
  end (`widgets/action_row.dart`) and an "in use" mark on the method Codex runs
  on; no disclosure. The state names the credential in words and reports an
  unreadable `config.toml`.
- On a phone, Codex setup says where sign-in and hosting happen instead of
  offering them. Mobile Codex setup never reads local Codex state
  (`CODEX_HOME`) and never offers its local prompt-option change; it shows
  host guidance instead.

## Fonts

- Prose is Google Sans Flex and code Geist Mono, Latin-only and bundled on
  every platform (`fonts:` in `apps/flutter/pubspec.yaml`); Windows keeps
  Segoe UI as its UI face.
- Chinese renders thin and unevenly weighted on Windows with Flutter's default
  fonts, so **desktop** builds also bundle **Noto Sans SC**
  (`apps/flutter/assets/fonts/`, SIL OFL 1.1), first in `cjkFontFallback`
  (`lib/src/fonts.dart`). Mobile and web fall through to the OS CJK font
  (PingFang SC / Noto Sans CJK). The gate is `defaultTargetPlatform`, so
  `flutter test` (forced to android) takes the mobile branch.
- To keep its ~17 MB out of Android/iOS artifacts, Noto Sans SC is declared
  only in `apps/flutter/pubspec-desktop.yaml`, a copy of `pubspec.yaml` (the
  source of truth for dependencies, used by mobile, tests and local dev) plus
  that `fonts:` entry. The desktop release jobs (`app-windows` / `app-linux` /
  `app-macos` in `.github/workflows/release.yml`) `cp pubspec-desktop.yaml
  pubspec.yaml` before building. **Keep its dependencies in sync with
  `pubspec.yaml`.**

To preview the bundled font locally on desktop:

```bash
cp apps/flutter/pubspec-desktop.yaml apps/flutter/pubspec.yaml
(cd apps/flutter && fvm flutter pub get && fvm flutter run -d windows)
git checkout -- apps/flutter/pubspec.yaml   # restore before committing
```

## Branding and generated art

- Branding uses the UI's blue/neutral palette. The mark has one source: the
  vector drawing and `MarkStyle` palettes in `apps/flutter/test/gen_icon_test.dart`
  (blue tile for launchers, the Windows/Linux tray and README art; a
  one-colour template glyph `assets/tray/tray_template.png` for the macOS menu
  bar; theme surfaces for splash and the in-app glyph; the multi-size Windows
  `app_icon.ico`). Dock and menu-bar rules: [macOS distribution](macos-release.md).
- After changing the mark, regenerate for every platform, keep both logo
  copies (`assets/logo/logo.png`, `apps/flutter/assets/logo/logo.png`) in sync
  and the splash colours equal to the `MarkStyle` tiles:

  ```bash
  cd apps/flutter
  REGEN_ICONS=1 fvm flutter test test/gen_icon_test.dart
  fvm dart run flutter_launcher_icons
  fvm dart run flutter_native_splash:create
  ```

- `test/gen_poster_test.dart` composes the README poster at 2x from the mark,
  the POCOX wordmark and the app's own galaxy, Local sessions and chat screens
  rendered with fixture data (never a real session). Rerun it with
  `REGEN_ICONS=1` when the mark, an agent mark (`widgets/agent_icon.dart`,
  shown in its chips), the galaxy or the chat design changes.
- The README's agent logos (`assets/readme/*.svg`) copy the path data of
  `widgets/agent_icon.dart`; update them when an agent mark changes.

## UI tests

- Responsive coverage: `test/responsive_layout_test.dart` (320 px at 2.0
  text en/zh, 393 px, keyboard, landscape, tablet, real fonts),
  `test/chat_status_bar_test.dart` and `test/phone_pages_overflow_test.dart`
  (393/375/360/320 px, ×1.0–2.0 text, en/zh).
- Widget tests mock haptics and cover the system pointer cancel. A test
  holding an operation pending pumps bounded frames: its progress never
  settles.
- Long-history issues reproduce with the opt-in native integration test in
  [history cache › Verification](session-cache-sync.md#verification).
- Required checks: [AGENTS.md › Verification](../AGENTS.md#verification).

## References

- T3 Code's [virtualized timeline and scroll anchoring](https://github.com/pingdotgg/t3code/blob/cfeaca41ae27bdf2c203158d378c87c7308fea2a/apps/web/src/components/chat/MessagesTimeline.tsx)
  and [pagination state tests](https://github.com/pingdotgg/t3code/blob/cfeaca41ae27bdf2c203158d378c87c7308fea2a/packages/client-runtime/src/state/threads-pagination.test.ts).
- T3 Code's [bounded work list and long-message folding](https://github.com/pingdotgg/t3code/blob/af2baccd100604f9885d6af97a5fa99622dd1c4f/apps/web/src/components/chat/MessagesTimeline.tsx)
  preserves scroll anchors and virtualizes expanded activity. Our adaptive tick
  sampling and step-range controls are POCOX adaptations, not claimed upstream
  behaviour.
