# POCOX usage guide

> 中文版：[`docs/usage.zh-CN.md`](usage.zh-CN.md)

One machine stays logged in to Codex; your other devices drive it. They find each
other through the backend in one of two ways: **a pairing code**, with no account at
all, or **the same GitHub account**. Either way there is no relay address or shared
key to manage: the backend issues your devices a credential and they meet on the
relay.

> Running your own relay instead? See [CLI › Self-host](cli.md#self-host).
> Hosting the backend yourself? See [`deploy/README.md`](../deploy/README.md).

---

## 0. Before you start

- A **`pocox-backend`** must be reachable. Someone runs it once (you, or
  whoever owns your server). The CLI and app use a built-in default backend; to
  point at your own, pass `--backend https://your-host` to `login` or `pair` (it is
  remembered) or set it in the app's advanced settings.
- The **host machine** (the one that exposes Codex) needs a working `codex`
  binary on `PATH`. Client devices do **not** need Codex installed — except for
  the CLI `connect` path, which runs a local `codex --remote`.

---

## 1. Sign in with a pairing code

Every device has one code of its own, like `K7M2-F9QX-3RTB`. Devices linked by their
codes count as one user and reach each other's services. No account, email or phone
number is involved. The backend must have pairing turned on
([deploy](../deploy/README.md#pairing-code-login-optional)).

### Your first device

Open the app. A computer shows its own code with a QR code; choose **Get started**.
A phone leads with a field for another device's code, so on your first device choose
**This is my first device**. From the CLI, `pocox pair` shows the code and asks to
set the device up.

### Adding a device

On the new device, enter or scan the code of any device you already use: **Enter
another device's code** on a computer, the code field (or its scan button) on a
phone, `pocox pair join` in a terminal. The next page shows the group's devices;
nothing is linked until you choose **Link**. To show a code to the new device, open
**Settings › Account › Add device** on one you already use.

A code lets whoever has it link a device at once, with no approval, and use your
hosted services; your devices are told only afterwards ("Pixel linked. Not yours?").
Share it only with your own devices. If a code leaks, on the device whose code it is
turn off **Allow linking with this code** (`pocox pair pause`) at once, remove any
device you do not recognise in **Settings › Account** (`pocox devices remove`), then
**Change code** (`pocox pair rotate`) once a day has passed since it was issued.

### A QR code or link only opens a preview

Scanning a pairing QR code, or opening a `pocox://pair` link, fills in the code and
shows the same preview as typing it. It never links by itself. Links open the app on
iOS, Android and macOS; on Windows and Linux, type the code.

### Restoring a device

On a reinstalled or reset device that lost its identity (see below), choose **Restore
a previous device** under **Other ways to sign in**, or `pocox pair restore`. Do it
before choosing **Get started**, **This is my first device**, **Continue** or **Link**:
once a device is set up, it can only join its group again as a new device.

- **With a code** from any device in the group: pick which device this one was. One
  that was active today asks again, since restoring it stops it there.
- **Ask a linked device**, when you have no code at hand: this device shows a check
  number. On a linked device, **Settings › Account** shows the request with the same
  number; **Allow** it there (`pocox devices allow` in a terminal), then confirm here.
  The backend finds the device by its hardware, so this works only on macOS, Windows
  and Android 8 or later, on the same hardware, and not after a phone's factory
  reset. On iOS, Linux or a reset phone, use a code.
- **Continue as a new device** is always open instead.

When one of your devices is restored somewhere you did not intend, that device says
so, with the time its access ends, and offers **Take back and change code**: the
other copy's access ends at once and the code changes. In a terminal on that device,
run `pocox pair start-over`, then `pocox pair restore --retake`; on a replacement
device not yet set up, `pocox pair restore --retake` alone.

### Settings › Account

Lists every linked device, with rename and remove. **Add device** shows this device's
code and QR code. Recovery requests appear here with their check numbers. Also here:

- **Allow linking with this code** pauses the code: nobody can link with it until
  you turn it back on.
- **Change code** retires the current code, at most once a day.
- **Link to other devices instead** joins a different group.
- **Leave these devices**: this device continues on its own with its own code.
- **Switch to GitHub** returns to a GitHub account, and **Use a pairing code** (on a
  GitHub or self-hosted installation) comes back.

The CLI has the same: `pocox devices`, `pocox devices remove`, and `pocox pair
pause`, `resume`, `rotate` and `leave` ([CLI](cli.md#pairing-codes)).

### Reinstalling

A device keeps its identity in a private store. Phones keep it out of backups, so a
backup cannot restore it onto another phone; on a computer it is a file in your user
data:

| Platform | After a reinstall |
| --- | --- |
| iOS | The identity is in the Keychain, on this device only, so deleting and reinstalling the app usually resumes it (Apple does not promise this): same device, same code. |
| Android | The identity lives in app storage that no backup copies, so uninstalling deletes it. A local Block Store copy may bring it back on the same phone, best effort: it needs Android 8 or later, Google Play services and Google backup turned on, and has not yet been tested on a device. |
| macOS, Windows, Linux | The identity sits in the account's application data, shared by every POCOX on that OS account, CLI included, and survives reinstalling the app. A backup or migration of your home folder copies it (only Time Machine on macOS skips it). A copy that reaches another computer acts as this device: remove that device from another of yours, or take it back with `pocox pair start-over`, then `pocox pair restore --retake`. |

Without its identity a device starts on the first screen: restore it as above (on
iOS and Linux, with a code), or continue as a new device.

### What a removed device keeps

Removing a device stops its **new** connections at once. Connections already relayed
close; a direct (P2P) connection already set up may last until either end closes it,
which is why the app says new connections stopped. The removed device keeps its own
sessions and settings, and can continue on its own. When a device's identity is
restored elsewhere, its old secret keeps working for 600 seconds, then stops; the old
device says so and offers to take the identity back.

---

## 2. Sign in with GitHub

### App

Both GitHub sign-ins are under **Other ways to sign in**:

- **Sign in with GitHub** opens GitHub in the browser; authorize, and the browser
  hands you back to the app.
- **GitHub device code** shows a short code; enter it at `github.com/login/device`
  and authorize.

Either way you land on the home screen, which shows the account you signed in as.

### CLI

```bash
pocox login
```

This prints a verification URL and a one-time code. Open the URL, enter the code,
authorize. Confirm with:

```bash
pocox account     # → signed in as @you, mode = account
```

---

## 3. Host your Codex

On the machine that has `codex` installed and logged in:

```bash
pocox serve
```

This starts (or reuses) the local `codex app-server` and registers it under your
account. Leave it running — this is what your other devices connect to.

Useful options:

- `--name work` — run more than one (each service gets its own name).
- `--proxy http://…` — reach `chatgpt.com` through an upstream proxy.

---

## 4. Drive it from any device

Link the other device (section 1), or sign in to the **same** GitHub account on it,
then:

### App (recommended)

The home screen lists your app-server with a live health dot. Tap it, then:

- **New conversation** (the **＋** button); pick a working directory.
- Type a prompt and send. **Thinking** and **tool calls** stream in live with an
  elapsed timer.
- Composer controls: **model**, **approval mode**, **working directory**,
  **plan mode**, and **reasoning effort**.
- **Approvals** — when Codex asks to run a command or apply a patch, approve or
  deny it inline.
- **Stop** interrupts a running turn.
- Re-open a conversation any time to see its history — and live progress if a
  turn is still running.

### CLI

```bash
pocox services list      # see your registered services
pocox connect            # subscribe; prints the exact codex command
codex --remote ws://127.0.0.1:28080
```

`connect` exposes the remote app-server on a local port and prints the
`codex --remote …` line to run a normal Codex session against it. Pick a specific
host/instance with `--device <id>` / `--name <name>` when you have more than one.

---

## 5. Use it as an OpenAI-compatible API (optional)

Reach your Codex login as a standard Responses API from any device.

On the host:

```bash
pocox api serve
```

On any device:

```bash
pocox api connect        # prints a local model_providers config snippet
```

Point any OpenAI-compatible tool at the printed local endpoint (it serves
`/v1/responses`). In the app, the API service appears on the home screen with its
own health indicator.

---

## 6. Status & sign out

```bash
pocox account            # who you are + transport mode
pocox status             # local serve / api / codex state
pocox stop               # stop the local serve / api
pocox logout             # revoke the session + clear the local token
```

In the app: **Settings → Account → Sign out**. For a pairing device, `pocox logout`
and **Sign out** sign this installation out but keep its identity and group:
`pocox pair` or the first screen's **Continue** resumes it. To end a device's access,
remove it from another device.

---

## Troubleshooting

- **"app-server unreachable" in the app** — the host's `pocox serve` isn't
  running or lost its connection. (Re)start it on the host. The app re-probes
  periodically; the refresh control forces an immediate check.
- **Login expired** — run `pocox login` again. While a session is valid it
  refreshes automatically, so you normally only log in once per device.
- **Multiple hosts or services** — give each a `--name`, then select it with
  `--name` / `--device` on the CLI, or by tapping the right service in the app.
