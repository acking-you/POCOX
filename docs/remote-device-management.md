# Remote device management

Another authorized device (a phone included) can manage the services of an
online desktop host: add a service, change its configuration, and start,
apply or stop it. The host also offers a default project folder for new
conversations. This page describes the product behavior of the Flutter
client; the wire contract lives in the Rust host and bridge.

## CLI host

Run the same native hosting and management engine without Flutter:

```sh
pocket-codex serve --allow-remote-management --device my-computer \
  --name default --codex-binary /path/to/codex
```

This explicit opt-in stays in the foreground in both account and self-host
mode. It publishes the management-only `host:pocket` entry plus the initial
Codex host's `app`, `api` (Responses API) and `meta` services. The management
routes, installed-runtime discovery, revision/incarnation checks, write-only
secrets and process ownership are the desktop engine's existing implementation.
All services bind loopback; relay traffic is encrypted. The transport is chosen
as for ordinary `serve`: an explicit `--relay`, or any self-host setup, resolves
its credential from the flag, saved configuration or `PB_MAPPER_SERVER` /
`MSG_HEADER_KEY`; a signed-in account renews its own. Exact `--key`,
non-loopback `--host`, and extra Codex arguments are unsupported in this mode;
ordinary `serve` is unchanged.

The CLI reads its existing account/relay configuration. Its managed-service
profiles and authoritative restore choices live separately from the desktop
app under `<state-dir>/managed-host/hosting`. `--name`, `--port`,
`--codex-binary` and `--proxy` seed the initial host only when it has no saved
lifecycle choice. Subsequent starts restore saved configuration; a remotely
stopped service stays stopped, even the initial one. A saved service that cannot
start (its agent was uninstalled, its port is taken) is logged and left for
repair from another device; it never keeps management offline. Only an
unreadable restore ledger stops startup, since its choices would be guesses.
Management remains online after the last service stops. SIGINT/SIGTERM (and on
Windows Ctrl-Break, closing the console window or system shutdown) stops
owned services without changing their restore choices. A process lock prevents
two CLI supervisors from owning the same state directory.

`pocket-codex status` includes the supervisor and its managed services while a
supervisor holds that lock, from the private report it rewrites whenever its
state changes. Failing to save that report is logged and never stops a service.
An enabled but offline management registration is `pending`. For systemd,
append `--allow-remote-management` to `ExecStart`; keep the service in the
foreground and allow enough stop time for its owned agents to exit.

## Management entry

### Publisher identity and platform

Every new host publishes `GET /host/device` on its registered `meta` listener
(Codex, OpenCode and ACP), on the management listener, and on the standalone
Responses API proxy. The shared version-1 metadata contains `os`, `arch`,
`environment` (`wsl` where the Linux kernel identifies WSL), `hostname`, optional
`sourceName` (the WSL distribution name when the process inherited it, as a shell
does and a systemd unit does not, else the Linux distribution), optional stable
`hostId`, and an opaque `instanceId` renewed for each publisher process. `/manage/v1/device`
also includes this metadata, so managing a computer needs no extra request.
The OS comes from the publisher executable; WSL is Linux, independently of
the Windows controller. Metadata contains no credentials or filesystem paths.

This uses existing service registrations rather than extending
pb-mapper's key-only discovery protocol: no relay upgrade, additional public
listener, or change to discovery's wire format is needed. A selected unmanaged device reads
one metadata endpoint through its existing tunnel; the UI never probes every
device for metadata, and reads it again only on an explicit refresh: it changes
only when the host restarts. The header shows nothing while that read is in
flight, and "Platform unknown" once there is nothing more to wait for; an older
management view can still supply its existing `os` field. An older host's
404/405 (and an older standalone API proxy's 403) mean no metadata; other
connection errors are not interpreted as proof of an old host or a local
computer.

The local device is always an independent UI target, even before its first
host starts or with management disabled. Only exact service keys owned by the
current app's native host registry belong there. A matching hostname, OS,
relay device label or shared Windows/WSL filesystem does not make a service
local. Local controls never appear under a remote device. The local editor
names its target environment, and remote runtime choices still come from the
target host's runtime inventory.

### Several instances on one computer

Hostname is a display name. Windows, WSL distributions, native Linux and
separate hosting installations can share it without being the same host.
Each installation persists a random `hostId` and its default relay device name
before publishing. OS and native/WSL environments use separate identity records,
even if they share an identity directory. Independently running hosts still
require separate hosting/profile state directories. CLI publishers share `<state-dir>/identity`;
the desktop app uses `<app-support-dir>/identity`. Different data directories
are independent installations. Neither identity contains a hardware fingerprint.

The generated device segment is `<source>.<hostname>.<host-id-without-hyphens>`;
source includes OS/environment and the distribution when available. Neither
label contains a dot, so controllers split the segment without asking the host.
All services from that installation share it. The saved device segment and
`hostId` survive process restarts, hostname changes and distribution upgrades;
only `instanceId` changes on restart. Routing always keeps the full key; people
see `studio (WSL Ubuntu)` in the device list, host switcher, composer and page
titles, and the device list adds a short stable ID only where two installations
would otherwise read the same. The selected device's header shows its reported
platform and short ID. It never merges Windows and WSL by hostname. Explicit
`--device` names and older hostname-only names are shown as they are. Old
metadata without `hostId` remains supported.

**Default-name migration:** the first upgraded start without `--device` publishes
the new installation-scoped default instead of the former hostname-only key.
Rediscover and select that host in controllers; saved targets and caches for the
old key are not rewritten. Existing key formats remain discoverable/connectable.
An explicit `--device` (or ordinary serve's exact `--key`) keeps its existing
routing value; independent publishers must use different overrides. Metadata
cannot fix a deliberate duplicate key. Back up identity files with hosting state;
a corrupt or unreadable identity blocks publishing under the default name rather
than silently replacing published keys. The desktop app still starts and
controls other devices; with an explicit `--device` the identity only annotates
metadata, so a damaged one is reported and hosting continues.
Copying the complete identity directory clones an installation's identity. Use
separate fresh state directories for independently running clones; this does not
try to detect physical machines or split a deliberately shared installation.

### Discovery and permissions

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
  path or argv is accepted remotely. Several OpenCode services may run; one
  added beside a service on OpenCode's shared history gets a history of its
  own, chosen on the host ([Native OpenCode](opencode-native.md#hosting)). A
  new service's name must differ from every service there, compared as the
  relay compares names; the editor says so before Start.
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
- The local editor uses this device's `hostConfigSupported` answer. Remote
  runtime choices use the selected host's inventory and capabilities.
