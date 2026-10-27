import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/widgets/glass.dart';
import 'package:pocox/src/widgets/glass_stepper.dart';
import 'package:pocox/src/widgets/group_card.dart';
import 'package:pocox/src/widgets/setting_row.dart';

/// How many conversation services stay connected across switches, and which
/// idle one goes first: two quiet rows that save as they change, the same on
/// phone and desktop. A failed save puts the saved value back and says so on
/// its row.
class ConnectionWindowSettings extends ConsumerStatefulWidget {
  /// Creates the group.
  const ConnectionWindowSettings({super.key});

  @override
  ConsumerState<ConnectionWindowSettings> createState() => _SettingsState();
}

/// The row a failed save belongs to.
enum _Row { capacity, eviction }

class _SettingsState extends ConsumerState<ConnectionWindowSettings> {
  /// What the bridge has saved.
  ConnectionWindowPreferences? _saved;

  /// What the controls show: [_saved], or a change still being saved.
  ConnectionWindowPreferences? _shown;

  bool _readFailed = false;
  _Row? _failed;

  /// A change made while another was being saved, and its row; it is
  /// saved next.
  (ConnectionWindowPreferences, _Row)? _queued;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _readFailed = false);
    try {
      final value = await ref
          .read(bridgeApiProvider)
          .connectionWindowPreferences();
      if (mounted) setState(() => _saved = _shown = value);
    } catch (_) {
      if (mounted) setState(() => _readFailed = true);
    }
  }

  void _change(ConnectionWindowPreferences next, _Row row) {
    setState(() {
      _shown = next;
      _failed = null;
    });
    if (_saving) {
      _queued = (next, row);
    } else {
      _save(next, row);
    }
  }

  /// Saves [next], then the latest change made meanwhile.
  Future<void> _save(ConnectionWindowPreferences next, _Row row) async {
    _saving = true;
    var (value, current) = (next, row);
    try {
      while (mounted) {
        await ref.read(bridgeApiProvider).setConnectionWindowPreferences(value);
        _saved = value;
        final queued = _queued;
        _queued = null;
        if (queued == null || queued.$1 == value) break;
        (value, current) = queued;
      }
    } catch (_) {
      _queued = null;
      if (mounted) {
        setState(() {
          _shown = _saved;
          _failed = current;
        });
      }
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final shown = _shown;
    String? state(_Row row) =>
        _failed == row ? l10n.connectionPathSaveFailed : null;
    final policies = <GlassSegment<ConnectionEviction?>>[
      GlassSegment(
        key: const Key('connection-window-lru'),
        value: ConnectionEviction.lru,
        label: l10n.connectionWindowLru,
      ),
      GlassSegment(
        key: const Key('connection-window-fifo'),
        value: ConnectionEviction.fifo,
        label: l10n.connectionWindowFifo,
      ),
    ];
    return GroupCard(
      key: const Key('connection-window-settings'),
      title: l10n.connectionWindowTitle,
      info: l10n.connectionWindowDescription,
      children: [
        if (_readFailed)
          SettingReadFailed(
            icon: AppIcons.layers_outlined,
            message: l10n.connectionPathReadFailed,
            retryLabel: l10n.retry,
            retryKey: const Key('connection-window-retry'),
            onRetry: _load,
          )
        else ...[
          SettingRow(
            icon: AppIcons.layers_outlined,
            title: l10n.connectionWindowCapacity,
            state: state(_Row.capacity),
            stateKey: const Key('connection-window-state'),
            failed: _failed == _Row.capacity,
            control: (_) => GlassStepper(
              key: const Key('connection-window-capacity'),
              decreaseKey: const Key('connection-window-capacity-decrease'),
              increaseKey: const Key('connection-window-capacity-increase'),
              semanticLabel: l10n.connectionWindowCapacity,
              // Nothing to step until the saved value is known.
              value:
                  shown?.capacity ??
                  const ConnectionWindowPreferences().capacity,
              min: ConnectionWindowPreferences.minCapacity,
              max: ConnectionWindowPreferences.maxCapacity,
              onChanged: shown == null
                  ? null
                  : (capacity) => _change(
                      shown.copyWith(capacity: capacity),
                      _Row.capacity,
                    ),
            ),
          ),
          SettingRow(
            icon: AppIcons.history,
            title: l10n.connectionWindowPolicy,
            info: l10n.connectionWindowPolicyInfo,
            state: state(_Row.eviction),
            stateKey: const Key('connection-window-state'),
            failed: _failed == _Row.eviction,
            stackWhenNarrow: true,
            controlWidth: GlassSegmented.naturalWidth(context, policies),
            control: (expand) => IgnorePointer(
              ignoring: shown == null,
              child: GlassSegmented<ConnectionEviction?>(
                key: const Key('connection-window-policy'),
                expand: expand,
                selected: shown?.eviction,
                onChanged: (eviction) {
                  if (shown != null && eviction != null) {
                    _change(shown.copyWith(eviction: eviction), _Row.eviction);
                  }
                },
                segments: policies,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
