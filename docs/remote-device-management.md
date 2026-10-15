# Remote device management

Another authorized device (a phone included) can manage the services of an
online desktop host: add a service, change its configuration, and start,
apply or stop it. The host also offers a default project folder for new
conversations. This page describes the product behavior of the Flutter
client; the wire contract lives in the Rust host and bridge.

## Management entry

- A desktop host publishes one relay service of kind `host`
  (`pcx:<device>:host:<name>`, `pcxu:<user>:<device>:host:<name>` in account
  mode). It is a management entry only: never a conversation, model or API
  service, and it is never listed as a capability row.
- Devices are grouped by device. A device with only its `host` entry (every
  service stopped) stays listed, so management survives the last stop.
- Only another computer gets the management panel. This device's own hosts
  keep the local hosting controls; older hosts without a `host` entry still
  connect and chat but show no management.
- The switch (**Allow management from other devices**) is local-only: only
  the computer itself can turn it on or off, and turning it changes no
  running service. Phones have no local hosting, so no switch.

## Services on a remote computer

- **Add service** lists only runtimes the host reports as installed: Codex,
  native OpenCode, the Claude preset, or a saved configuration. No executable
  path or argv is accepted remotely. OpenCode is one per computer.
- Discovery never installs or signs in. Claude's adapter is prepared only
  by an explicit **Prepare**, with measured progress. A runtime that needs a
  sign-in on the host explains that the sign-in happens there.
- The editor reuses the local model-service form. A saved ACP agent other
  than the Claude preset keeps its own name and support (existing
  configuration only); its private launch is never shown or sent. Secrets are write-only:
  the key is kept, removed or replaced explicitly, and a masked base URL or
  proxy that was not edited is kept as stored (`keepBaseUrl`, `keepProxy`,
  `runtime: null`).
- Every mutation names what was read: Save sends the revision, Apply the
  revision and the running incarnation, Stop the incarnation. A conflict
  keeps the edits and asks for an explicit reload.
- A lost answer is reported as unknown and the state is refreshed; nothing
  is sent again automatically.
- An unreadable saved configuration is shown as a problem: its placeholders
  are never offered for saving, and Stop stays available.
- Restore-persistence warnings are shown beside, never instead of, the
  start or apply result.

## Automatic restore

The host's restore overrides are authoritative on a desktop cold start: an
override with no runtime means stopped (locally or from another device) and
suppresses older UI preferences for that name; remotely added hosts restore
too. If the overrides cannot be read, nothing is restored and the reason is
shown under the switch. Each restore is revalidated by the host
(`hostRestoreService`); a stopped host is never restarted by polling.

## Default project folder

- **Default project folder** replaces the accessible-folders list as the main
  setting. Accessible folders move under **Advanced** and still restrict
  browsing; nothing grants the whole home directory.
- Without a chosen default the host shows its automatic folder. It is
  created only when the first conversation that needs it is created.
- A new conversation without a chosen folder shows the default as its
  project and sends with no cwd; the host resolves and creates it. An
  explicit folder always wins, and a late default never replaces the user's
  choice or another project's draft. Each later new conversation reads the
  host's current default again.
- Once the host lists a conversation created that way, the view takes the
  folder the host reports for it (never a guess), on the same host,
  connection and conversation only.
- A failed creation keeps the text, attachments and draft; nothing is
  merged or sent automatically.
- Saving the default passes the read revision; after a conflict nothing can
  be saved until an explicit reload.
  Older hosts (no revision) keep the folder picker requirement.

## Status page

The main view shows the running state, model/provider summary, default
folder and key actions. Ports, relay keys, binaries and longer explanations
sit under an expandable **Diagnostics** section; long values are selectable
and copyable.

**Add service** rows show only the runtime's name and a short status; paths,
versions and longer explanations sit behind each row's **Details**. The chat
host switcher has **Refresh services**, which re-reads discovery in place so
a service just started on another device appears without leaving the
conversation or its draft.

## Verification and limits

- Instrumented: widget tests with the fake bridge
  (`apps/flutter/test/managed_ui_test.dart`, `managed_add_service_test.dart`,
  `default_project_session_test.dart`, restore tests in `acp_hosting/` and
  `home_screen_test.dart`), including 320/393 px phones at 2x text in en/zh,
  light/dark and with the keyboard up.
- Real devices: the parent agent verified adding, editing and applying a
  service from a phone against the actual desktop host. The user then
  accepted the current functionality on the installed desktop and iOS apps;
  that is user acceptance, not an instrumented check.
- Not claimed: physical-phone haptics, other platforms.
- The remote editor's support matrix uses this device's `hostConfigSupported`
  answer.
