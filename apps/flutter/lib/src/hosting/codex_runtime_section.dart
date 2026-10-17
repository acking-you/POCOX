import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/acp_host_form.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/hosting/host_names.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';
import 'package:pocket_codex/src/widgets/group_card.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// Horizontal padding of each Codex source segment, the one
/// [segmentsFitAcross] counts for the disabled built-in segment.
const _sourceSegmentPadding = EdgeInsets.symmetric(horizontal: 12);

/// The port the first Codex host listens on by default.
const defaultCodexPort = 18080;

/// What a new native Codex host is started with: the codex binary (found
/// on `PATH` / in the saved configuration, or chosen), the instance name,
/// the upstream proxy and, under Advanced, the listen port.
///
/// Every new host gets a free instance name and, beside another Codex host,
/// an automatic port, so a second or third instance never collides with the
/// first by default. A running host's form is [prefill]ed from its saved
/// (else active) runtime and edits that runtime under its fixed name.
class CodexRuntimeForm extends ChangeNotifier {
  /// Creates the form; [api] detects codex.
  CodexRuntimeForm(this._api);

  final BridgeApi _api;

  /// Listen port (`0`: automatic).
  final port = TextEditingController(text: '$defaultCodexPort');

  /// Explicit codex path.
  final path = TextEditingController();

  /// Instance name.
  final name = TextEditingController(text: 'default');

  /// Upstream proxy. Codex needs one to reach chatgpt.com on most networks,
  /// so hosting defaults to a local HTTP proxy unless turned off.
  final proxy = TextEditingController(text: 'http://127.0.0.1:11111');

  bool _nameEdited = false;
  bool _portEdited = false;
  bool _disposed = false;

  /// Whether the proxy is used.
  bool useProxy = true;

  /// Whether Advanced (the port) is open.
  bool advanced = false;

  /// The user chose to set the codex path themselves.
  bool overridePath = false;

  /// The detected codex, or null when not found.
  String? found;

  /// Whether detection finished.
  bool checked = false;

  int _detectSeq = 0;

  /// Moves on every explicit codex-path decision (typing, picking a file,
  /// "change path"), agent switch and start. A late detection or file pick
  /// applies only while it is unchanged.
  int pathIntent = 0;

  /// The user changed a field.
  bool touched = false;

  // What a running host's form was filled with.
  HostRuntime? _baseline;

  /// Mark the name as typed; suggestions no longer replace it.
  void nameEdited() {
    _nameEdited = true;
    edited();
  }

  /// Mark the port as typed.
  void portEdited() {
    _portEdited = true;
    edited();
  }

  /// A field changed by the user.
  void edited() {
    touched = true;
    changed();
  }

  /// The user takes the codex path into their own hands (typing it, or
  /// "change path"): a late detection no longer replaces it.
  void customizePath() {
    overridePath = true;
    pathIntent++;
    edited();
  }

  /// Fill the fields from a running host's [runtime] (its saved desired
  /// runtime, else what it runs). Without a known executable the usual
  /// detection fills the path.
  void prefill(HostRuntime runtime) {
    // A detection begun before this (the new-host form's) never lands on
    // the running host's fields or baseline.
    _detectSeq++;
    _baseline = runtime;
    _nameEdited = true;
    _portEdited = true;
    pathIntent++;
    port.text = '${runtime.port}';
    useProxy = runtime.proxy != null;
    if (runtime.proxy case final value?) proxy.text = value;
    final binary = runtime.binary;
    path.text = binary ?? '';
    found = binary;
    overridePath = false;
    checked = binary != null;
    touched = false;
    changed();
    if (binary == null) unawaited(detect());
  }

  /// The runtime the fields describe, or why they cannot be used. [exact]
  /// names the executable even when it was detected (a running host's
  /// saved runtime); otherwise a detected one is left to the bridge.
  (HostRuntime?, String?) read(AppLocalizations l10n, {bool exact = false}) {
    final value = int.tryParse(port.text.trim());
    // 0 lets the engine pick a port; out-of-range values would wrap.
    if (value == null || value < 0 || value > 65535) {
      return (null, l10n.localHostPortInvalid);
    }
    final manual = found == null || overridePath;
    final typed = path.text.trim();
    if (manual && typed.isEmpty) return (null, l10n.codexPathRequired);
    final binary = manual ? typed : (exact ? found : null);
    final upstream = useProxy ? proxy.text.trim() : null;
    if (useProxy && (upstream == null || upstream.isEmpty)) {
      return (null, l10n.proxyRequired);
    }
    return (
      HostRuntime.codex(binary: binary, port: value, proxy: upstream),
      null,
    );
  }

  /// Whether a running host's fields differ from what they were filled
  /// with (edited fields that cannot be read count as changed). Fields the
  /// user has not touched are no edit, whatever a detection is doing: a
  /// pending or failed lookup leaves an unknown executable unreadable.
  bool differs(AppLocalizations l10n) {
    final base = _baseline;
    if (base == null || !touched) return touched;
    final (current, _) = read(l10n, exact: true);
    return current == null ||
        current.binary != base.binary ||
        current.port != base.port ||
        current.proxy != base.proxy;
  }

  /// Notify after a field or flag changed.
  void changed() {
    if (!_disposed) notifyListeners();
  }

  /// Fill untouched name and port fields with values free on this device.
  void suggest(List<AppServeStatus> hosts) {
    if (!_nameEdited) {
      name.text = uniqueHostName('default', {for (final h in hosts) h.name});
    }
    if (!_portEdited) {
      port.text = hosts.any((h) => h.isCodex) ? '0' : '$defaultCodexPort';
    }
    changed();
  }

  /// (Re-)resolve codex from `PATH` + saved configuration; only the latest
  /// detection counts.
  Future<void> detect() async {
    final seq = ++_detectSeq;
    final intent = pathIntent;
    final typed = path.text;
    checked = false;
    changed();
    String? result;
    try {
      result = await _api.codexLocate();
    } catch (_) {
      // Best-effort: an error reads as "not found".
    }
    if (_disposed || seq != _detectSeq) return;
    found = result;
    if (_baseline != null && result != null && intent == pathIntent) {
      // A running host whose executable was unknown: the detected one is
      // what it gets, not a user edit.
      _baseline = HostRuntime.codex(
        binary: result,
        port: _baseline!.port,
        proxy: _baseline!.proxy,
      );
    }
    checked = true;
    if (result != null && intent == pathIntent && path.text == typed) {
      path.text = result;
      overridePath = false;
    }
    changed();
  }

  /// Pick the codex binary; dropped when anything changed meanwhile.
  Future<void> browse(bool Function() stillApplies) async {
    final intent = pathIntent;
    final file = await openFile();
    if (file == null || _disposed) return;
    if (intent != pathIntent || !stillApplies()) return;
    path.text = file.path;
    overridePath = true;
    pathIntent++;
    edited();
  }

  @override
  void dispose() {
    _disposed = true;
    port.dispose();
    path.dispose();
    name.dispose();
    proxy.dispose();
    super.dispose();
  }
}

/// The "Runtime" section of a new Codex host: binary, name, proxy, port.
class CodexRuntimeSection extends StatelessWidget {
  /// Creates the section for [form].
  const CodexRuntimeSection({
    super.key,
    required this.form,
    required this.enabled,
    required this.onBrowse,
    this.fixedName = false,
    this.info,
    this.takenNames = const {},
  });

  /// The fields.
  final CodexRuntimeForm form;

  /// A running host: its name is shown, not editable.
  final bool fixedName;

  /// Names this device's other hosts use; a new host's name must differ.
  final Set<String> takenNames;

  /// Replaces the new host's explanation behind the title's info mark.
  final String? info;

  /// Whether the fields can be edited.
  final bool enabled;

  /// Pick a codex binary.
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: form,
      builder: (context, _) => GroupCard(
        key: const Key('codex-runtime-section'),
        title: l10n.hostRuntimeInfo,
        info: info ?? l10n.localHostHint,
        children: [EditorBlock(child: _fields(context, l10n))],
      ),
    );
  }

  Widget _fields(BuildContext context, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final children = <Widget>[
      LayoutBuilder(
        builder: (context, constraints) => SegmentedButton<bool>(
          key: const Key('codex-source'),
          // Side by side only while each label fits on one line.
          direction:
              segmentsFitAcross(
                context,
                constraints.maxWidth,
                [l10n.codexSourceExternal],
                disabled: [_builtinLabel(l10n)],
              )
              ? Axis.horizontal
              : Axis.vertical,
          style: const ButtonStyle(
            padding: WidgetStatePropertyAll(_sourceSegmentPadding),
          ),
          segments: [
            ButtonSegment(value: false, label: Text(l10n.codexSourceExternal)),
            // The built-in engine is not implemented: shown, marked as such,
            // never selectable.
            ButtonSegment(
              value: true,
              enabled: false,
              tooltip: l10n.codexBuiltinNote,
              label: Text(_builtinLabel(l10n)),
            ),
          ],
          selected: const {false},
          onSelectionChanged: enabled ? (_) {} : null,
        ),
      ),
      const SizedBox(height: 14),
    ];
    if (!form.checked) {
      children.add(const LinearProgressIndicator());
    } else if (form.found != null && !form.overridePath) {
      children.add(_available(context, l10n));
    } else {
      if (form.found == null) {
        children
          ..add(
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.codexNotFound,
                    style: TextStyle(color: scheme.error),
                  ),
                ),
                TextButton.icon(
                  key: const Key('redetect-codex-btn'),
                  onPressed: enabled ? form.detect : null,
                  icon: const Icon(AppIcons.refresh, size: 16),
                  label: Text(l10n.codexRedetect),
                ),
              ],
            ),
          )
          ..add(const SizedBox(height: 8));
      }
      children.add(
        Row(
          // The button is centred on the field it fills.
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                key: const Key('codex-path-field'),
                controller: form.path,
                enabled: enabled,
                decoration: InputDecoration(labelText: l10n.codexBinaryPath),
                onChanged: (_) => form.customizePath(),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              key: const Key('browse-codex-btn'),
              onPressed: enabled ? onBrowse : null,
              child: Text(l10n.chooseCodexPath),
            ),
          ],
        ),
      );
    }
    children
      ..add(const SizedBox(height: 12))
      ..add(
        HostNameField(
          fieldKey: const Key('codex-name-field'),
          controller: form.name,
          enabled: enabled,
          fixed: fixedName,
          taken: takenNames,
          onChanged: (_) => form.nameEdited(),
        ),
      )
      ..add(const SizedBox(height: 6))
      ..add(
        SwitchListTile(
          key: const Key('use-proxy-switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.useProxy),
          // Without one, what that risks: the switch's own consequence.
          subtitle: form.useProxy
              ? null
              : EditorNote(l10n.noProxyWarning, color: cautionColor(scheme)),
          value: form.useProxy,
          onChanged: enabled
              ? (v) {
                  form.useProxy = v;
                  form.edited();
                }
              : null,
        ),
      );
    if (form.useProxy) {
      children.add(
        TextField(
          key: const Key('proxy-field'),
          controller: form.proxy,
          enabled: enabled,
          decoration: InputDecoration(labelText: l10n.proxyLabel),
          onChanged: (_) => form.edited(),
        ),
      );
    }
    children.add(const SizedBox(height: 6));
    children.add(
      AdvancedToggle(
        key: const Key('codex-advanced-toggle'),
        open: form.advanced,
        onChanged: (open) {
          form.advanced = open;
          form.changed();
        },
      ),
    );
    if (form.advanced) {
      children.add(
        FocusHelp(
          help: l10n.localHostPortHelper,
          child: TextField(
            key: const Key('codex-port-field'),
            controller: form.port,
            enabled: enabled,
            decoration: InputDecoration(labelText: l10n.localHostPort),
            keyboardType: TextInputType.number,
            onChanged: (_) => form.portEdited(),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _available(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final status = Row(
      children: [
        Icon(
          AppIcons.check_circle,
          size: 18,
          color: successColor(theme.colorScheme),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            l10n.codexFoundAt(form.found!),
            style: helpTextStyle(
              theme,
            ).copyWith(color: theme.colorScheme.onSurface),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    final customize = TextButton(
      key: const Key('customize-codex-btn'),
      onPressed: enabled ? form.customizePath : null,
      child: Text(l10n.customizeCodexPath),
    );
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth < 320
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [status, customize],
            )
          : Row(
              children: [
                Expanded(child: status),
                customize,
              ],
            ),
    );
  }

  /// The disabled built-in segment's label, marked as not implemented.
  static String _builtinLabel(AppLocalizations l10n) =>
      '${l10n.codexSourceBuiltin} · ${l10n.codexBuiltinUnavailable}';
}
