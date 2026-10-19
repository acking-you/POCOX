# Grok Build

POCOX hosts [Grok Build](https://x.ai/cli) (the `grok` CLI) as a built-in ACP
preset, offers its own sign-in or a custom provider as the host's model
service, and reads and manages the sessions Grok stores on this computer.
Like every agent, Grok runs as the user's installed executable; POCOX
neither builds nor bundles it.

The upstream source is a git submodule, `deps/grok-build`, on the `pocox`
branch of [acking-you/grok-build](https://github.com/acking-you/grok-build).
That branch starts from the fork's `upstream` branch, a pristine mirror of
the SpaceXAI tree (`SOURCE_REV` names the monorepo commit). It is a
reference for the wire surface and the storage format, never a Cargo
dependency: the readers below mirror its rules in first-party code, because
the crates that implement them (`xai-grok-shell`) pull in over a hundred
runtime dependencies. File references below are relative to
`deps/grok-build/crates/codegen`.

## The preset

| | |
| --- | --- |
| Profile id | `grok` (mark: a plain "G" monogram; no openly licensed Grok mark exists) |
| Command | `grok agent --no-leader stdio` (`--no-leader` keeps the agent in this one process instead of a shared leader socket) |
| Located | the child `PATH`, then `~/.grok/bin` (the official installer's link) |
| Code | `crates/pocket-codex-host-svc/src/acp/grok.rs`, `acp/spec.rs` |

Grok's own CLI speaks ACP v1, so no adapter is involved. Installed Grok 1.0.4
negotiates `session/load`, `session/list`, `session/resume`,
`session/close` and HTTP MCP servers; it advertises no image or audio
prompts, so attachments stay off. Its `initialize` lists the `grok.com` auth
method. POCOX answers permission requests with Grok's exact option ids
(`allow-once`, `always-allow`, ...). Model and effort chips appear when
Grok sends ACP `configOptions` (`model`, and `reasoning_effort` in the
`thought_level` category), which the upstream source does; 1.0.4 still
sends the older unstable `models` state instead, which POCOX does not use,
so its hosts run on their configured default model. Grok's own steering
extension (`_x.ai/interject`) is not mapped: running-turn messages queue
for the next turn.

A host with no sign-in and no key reports `authRequired` when a session is
created. Its host details and chat hint point at the Grok-account sign-in
below rather than "sign in with the agent's CLI".

## Model service

| Source | What the agent gets |
| --- | --- |
| Existing configuration | the user's own `$GROK_HOME` (`~/.grok`) and environment, unchanged: its sign-in, `XAI_API_KEY`, or models defined in its `config.toml` |
| Official account | the same home, with `XAI_API_KEY`, `GROK_CODE_XAI_API_KEY`, the endpoint overrides (`GROK_MODELS_BASE_URL`, `GROK_MODELS_LIST_URL`, `GROK_XAI_API_BASE_URL`, `GROK_CLI_CHAT_PROXY_BASE_URL`), the `GROK_CONFIG` / `GROK_CONFIG_PATH` overlays and `GROK_DEFAULT_MODEL` removed from the child's environment, so it uses the Grok account signed in on this computer. Before it starts (or is applied), a private `grok` on that route reports the default model it would use; the start is refused when that model is one the user defined in the home's `config.toml` (a `[model.*]` table by key, `id` or `model`, including one that overrides a built-in model's endpoint), and an unreadable `config.toml` cannot be checked and is refused too |
| Custom provider | Responses, Anthropic Messages or Chat Completions, with a required default model and key, in a Grok home of the host's own |

Variables are **removed**, not blanked: Grok reads the legacy
`GROK_CODE_XAI_API_KEY` untrimmed, so an empty value would still count as a
key (`process::spawn_without`, `HostOptions::env_remove`).

### Custom provider

Grok defines third-party models only as `[model.<id>]` tables in
`$GROK_HOME/config.toml`. Its `GROK_CONFIG` / `GROK_CONFIG_PATH` overlays
strip them (`xai-grok-config/src/config_override.rs`), and its env-only
custom endpoint expects xAI-shaped model lists. So a custom-provider host
gets its own Grok home, `<state>/acp-grok/<instance name>/`, and on every
start POCOX rewrites that home's `config.toml` (0600, atomically):

- one `[model."<id>"]` per model, with `base_url`, `api_backend`
  (`responses`, `messages` or `chat_completions`) and
  `env_key = "POCOX_GROK_PROVIDER_KEY"`. Only the child's environment holds
  the key, never the file. Grok treats a model with its own key as BYOK
  (`xai.api_key` auth) and never persists it;
- for Anthropic Messages, also `auth_scheme = "x_api_key"` and an
  `anthropic-version` header, which Grok's Messages client does not send
  itself. Installed 1.0.4 ignores `auth_scheme` and sends the key as a
  Bearer token, which Anthropic-compatible gateways generally accept and
  Anthropic's own API does not;
- `models.default` (the provider's default model) and
  `models.allowed_models` (only the provider's models, so Grok's built-in
  models that would need a sign-in are not offered).

Everything else Grok writes into that file is kept; a file that cannot be
read is left as it is and the start fails, rather than being replaced. The
models are what the
gateway's `/models` lists at start and Apply (the same bounded reader native
OpenCode uses). When the list cannot be read, only the default model is
configured and the start's toast says so; applying again retries. Text that
Grok would expand (`$`, `{`, `}`) or control characters are refused.

The child's environment also drops the user's Grok credentials and routing
(`GROK_AUTH`, `GROK_AUTH_PATH`, `GROK_OIDC_*`, `GROK_AUTH_PROVIDER_COMMAND`,
endpoints, overlays), so no sign-in of `~/.grok` reaches the gateway. The
host's sessions, sign-in and plugins live in its own home and are not shared
with `~/.grok`; that home is never deleted by POCOX. Its sessions are listed
by that host, not by Local sessions.

### Sign-in

The hosting editor's Official account choice shows Grok's sign-in in place
(`hosting/grok_login_panel.dart`, bridge `engine/grok_account.rs`). Each
status read, sign-in and sign-out runs a private, short-lived
`grok agent --no-leader stdio` on the Grok-account route
(`acp/grok_control.rs`). It is never a host, opens no session and sends no
prompt, so no host has to be running:

- status is `_x.ai/auth/info` (`methodId`, `email`);
- sign-in is Grok's device flow. `authenticate` with the advertised
  interactive method (`grok.com`, or `oidc` for an enterprise identity
  provider) answers once the user approved. Meanwhile `_x.ai/auth/get_url`
  hands out the verification URL once; the panel opens it and shows its
  code. Cancel is `_x.ai/auth/cancel`, and leaving the panel cancels too;
- sign-out is `_x.ai/auth/logout`.

Grok stores the sign-in in its own home (`auth.json`, shared with the `grok`
CLI). A host that is already running picks it up when it is restarted. At
most two sign-ins run at once. Quitting the app closes admission and stops
every sign-in's process group.

## Local sessions

Desktop **Local sessions** lists Grok beside Codex, Claude and OpenCode
(`native_history/grok.rs`). The source is this computer's `$GROK_HOME`
(or `~/.grok`); a home that does not exist is reported as unavailable, not
as an empty history, while an existing home may have no sessions yet. A Grok host on that home (existing configuration or Grok
account, never a custom provider's own home) continues a session.

### Listing

Sessions are `sessions/<encoded-cwd>/<session-id>/` directories holding
`summary.json` (`session/storage/relocation`). They are listed the way
Grok's own recent-session list lists them (`session/storage/jsonl`): plain
directories and files only (no symlinks), and an id stored under two cwd
buckets is skipped as ambiguous, as Grok skips it. Subagent children
(`hidden`, `session_kind` `subagent*`), one-shot `grok -p` runs
(`headless`) and never-used, untitled sessions with no messages are left
out. The title is `generated_title`, else `session_summary`. Order is
`last_active_at` (else `updated_at`), newest first. Summaries over 256 KiB
and more than 50,000 session directories are refused.

### Transcripts

`updates.jsonl` is Grok's durable log of the ACP `session/update`
notifications it sent. The reader replays it the way Grok's own
`session/load` does (`session/storage/mod.rs` `filter_rewind_by`,
`storage/replay.rs`):

- a counted user run opens a turn: every user run until the first
  `promptIndex` appears, afterwards only runs that carry one; host-turn
  chunks are not user runs;
- a `rewind_marker` (`_x.ai/session/update`) drops everything from the
  start of its target prompt;
- only ACP lines are shown, through the same fold as live ACP views.
  `_x.ai` lines supply a turn's outcome (`turn_completed`); the command
  catalog is skipped. User text loses `<fork-context>` /
  `<resume-context>` wrappers, and an interjection shows its typed
  `displayText`.

The index keeps that filter state, so a later read examines only appended,
complete lines (an unfinished last line waits). A read that fails keeps no
index, so a retry starts from the log again and never serves a partial index
as complete. Turn ids are the byte offset
of the turn's first line, so a rewound and rewritten turn never reuses an id.
Pages hold 20 turns by default, and the exact turn count is reported. A line
over 8 MiB is indexed but shown as omitted. A page folds at most 32 MiB,
and a session index holds at most 500,000 lines. The source generation is
the session directory and its creation time (the log's first write keeps
it). A shorter log shows as fewer `source_bytes`. The revision follows the
log and the summary.

### Who holds a session

Grok's terminal clients (the TUI and `grok -p`) register open sessions in
`$GROK_HOME/active_sessions.json` (`xai-grok-active-sessions`). An entry
counts as an owner only when its PID still runs a `grok` executable that
started before the entry was written. A dead PID is a crash leftover, and a
live process that cannot be shown to be that client makes the answer
unknown. Grok records no turn state, so a held session reads **In use
elsewhere** in Local sessions. In a host it is followed read-only with the
access reason `external_open`: the client has it open and whether a turn
runs there is unknown. It opens by itself once that client closes it.

`grok agent stdio` never registers, whether it runs in an editor or in
POCOX's own host. POCOX cannot see an editor's ACP Grok on the same
session: close it before continuing that session here. This is not a
provider-wide lease. A POCOX host admits a Grok session only from a fresh
check with no registered client and with the Pocket session claim (beside
Grok's home). Before every prompt it checks again that no client has
registered and that its agent is still the process it launched. Grok's
agent is the session's writer itself, unlike the Claude adapter's
registered native child. Hand back (`session/close`) and Continue here work
as for Claude.

### Rename and delete

A Grok row's menu renames or deletes the session through Grok itself:
`_x.ai/session/rename` sets `generated_title` and marks the title manual,
and `_x.ai/session/delete` removes the directory. Both run on a private
`grok` in the same home. Each is refused while a Grok terminal client has
the session open or a POCOX host holds its claim, and the claim is held for
the operation. Deleting asks first and cannot be undone. Other providers'
sources stay read-only (`NativeSessionList.manageable`).

## Remote management

A desktop that allows remote management offers Grok in another device's Add
service list when `grok` is installed there (`management::RuntimeChoice::Grok`,
kind `grok`). Like Codex, its Grok sign-in happens on that computer. A
remote start on the Official account first checks that account there:
Codex's ChatGPT sign-in for Codex, Grok's own sign-in (not a stored API key)
for Grok.

## Verification

On one Mac with Grok 1.0.4 (2026-10-20):

- Rust suites pass, including the Grok reader tests
  (`native_history/grok/tests.rs`: listing rules, pages, rewind, appended
  lines, interjections, owner verification with a real process named
  `grok`), the custom-provider home (`acp/grok.rs`), spawn variable
  removal, and the model-service matrix.
- The opt-in `tests/grok_live.rs` (`PCX_TEST_GROK=~/.grok/bin/grok`, run
  with `--ignored`) runs the real `grok agent --no-leader stdio` under the
  preset with a custom provider, aimed at a loopback Chat Completions
  endpoint. A real turn answered, with the key reaching the endpoint only
  from the child's environment. The native reader read back exactly the
  stored prompt and reply. The session was handed back and reopened on the
  same host. Grok reported the provider key as its auth method, and the
  session was renamed and deleted through Grok.
- The opt-in `engine/grok_account_tests.rs` ran, in a throwaway Grok home,
  the bridge's status read, a real device sign-in up to its verification
  URL and code (then cancelled; nothing signed in), and Local sessions
  rename and delete through `manage_session`.
- Separate probes against 1.0.4 confirmed the Responses and Anthropic
  Messages backends streaming through a generated home, and
  `allowed_models` limiting the catalog.
- Flutter tests cover the preset's mark, the three sources, the in-place
  sign-in with its code and cancellation, the start on the Grok account,
  Local sessions rename/delete/refusal and which Grok host continues a
  session.

Not verified: a completed Grok account sign-in and a turn on xAI's own
models (no account was signed in), a newer Grok that sends `configOptions`,
a Grok TUI holding a session live (covered by a real stand-in process),
the macOS app driven end to end, Linux, and remote management against a
real second device.
