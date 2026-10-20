/// The galaxy (`/galaxy`): every device the user can see as a star system,
/// its services as planets, connections as arcs of light, turning slowly.
/// Drag to orbit, pinch or scroll to zoom, tap a body to see and manage it.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_backdrop.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_list.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_frame.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_model.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_painter.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_panel.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_sprites.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_view.dart';
import 'package:pocket_codex/src/tools/planet_glyph.dart';
import 'package:pocket_codex/src/tools/tools_actions.dart';
import 'package:pocket_codex/src/tools/tools_providers.dart';
import 'package:pocket_codex/src/widgets/glass.dart';
import 'package:pocket_codex/src/widgets/height_reporter.dart';
import 'package:pocket_codex/src/widgets/utility_page.dart';

/// The galaxy page.
class GalaxyScreen extends ConsumerStatefulWidget {
  /// Creates the page.
  const GalaxyScreen({super.key});

  @override
  ConsumerState<GalaxyScreen> createState() => _GalaxyScreenState();
}

class _GalaxyScreenState extends ConsumerState<GalaxyScreen>
    with SingleTickerProviderStateMixin {
  final GalaxyView _view = GalaxyView();
  final LabelCache _labels = LabelCache();
  final GalaxyGeometry _geometry = GalaxyGeometry();
  final GalaxySprites _sprites = GalaxySprites();
  final Starfield _stars = Starfield();
  final FocusNode _focus = FocusNode(debugLabel: 'galaxy');
  final TextEditingController _search = TextEditingController();
  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;
  DateTime _touched = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _glide;
  bool _settled = true;
  bool _first = true;
  bool? _list;
  bool _listShown = false;
  double _pinch = 1;
  Size _canvas = Size.zero;

  /// The search bar's height (two rows on a phone, more with large text):
  /// the list and the details panel start below it.
  double _barHeight = 48;
  GalaxyScene _full = GalaxyScene.empty;
  GalaxyFilter _filter = const GalaxyFilter();
  ToolsOverview? _source;

  @override
  void initState() {
    super.initState();
    // Frames are computed in Rust once the bridge's export is found.
    GalaxyNative.load();
    _ticker.start();
  }

  @override
  void dispose() {
    _glide?.cancel();
    _ticker.dispose();
    _focus.dispose();
    _search.dispose();
    _view.dispose();
    _geometry.dispose();
    _sprites.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    final camera = _view.camera;
    final idle = _idleFor >= _glideAfter;
    if (idle && !_settled && _view.selected == null) {
      camera.overview();
      _settled = true;
    }
    if (_view.selected case final id?) {
      final at = _view.positionOf(id);
      if (at != null) camera.goalTarget = at;
    }
    camera.step(dt, drifting: idle && _view.selected == null && !_view.still);
    _view.time += dt;
    _view.tick();
    // Nothing moves in the list, or in a still scene once the camera rests:
    // stop drawing frames until something changes.
    if (_listShown || (_view.still && camera.settled)) {
      _ticker.stop();
      if (!_listShown && !_settled && _view.selected == null) {
        _glide = Timer(_glideAfter - _idleFor, _wake);
      }
    }
  }

  /// After this long without input the camera glides back to the galaxy.
  static const _glideAfter = Duration(seconds: 4);

  Duration get _idleFor => DateTime.now().difference(_touched);

  /// Draw frames again: something moved, changed or was asked for.
  void _wake() {
    _glide?.cancel();
    _glide = null;
    if (!mounted || _ticker.isActive) return;
    _last = Duration.zero;
    _ticker.start();
  }

  void _touch() {
    _touched = DateTime.now();
    _settled = false;
    _wake();
  }

  /// The backdrop arrived: paint it, unless this page is gone.
  void _backdropReady() {
    if (mounted) _view.tick();
  }

  /// Frame every system again (the device set or the canvas changed).
  void _refit({required bool entrance}) {
    var reach = 2.0;
    for (final system in _full.systems) {
      reach = math.max(reach, system.position.length + system.extent);
    }
    final camera = _view.camera..fit(reach, _canvas);
    _wake();
    if (entrance) {
      // The galaxy arrives from a little further out.
      camera
        ..overview()
        ..distance = camera.fitDistance * 1.35;
    } else if (_view.selected == null && _settled) {
      camera.overview();
    }
  }

  void _rebuild(ToolsOverview overview) {
    _source = overview;
    final before = _full.systems.length;
    _full = buildScene(overview);
    final scene = filterScene(_full, _filter);
    // Until the first catalog arrives nothing appears, so nothing animates in.
    _view.update(scene, first: _first);
    if (_full.systems.isNotEmpty &&
        (_first || before != _full.systems.length)) {
      _refit(entrance: _first);
      _first = false;
    }
    if (_view.selected case final id?) {
      if (scene.systemOf(id) == null && scene.planetOf(id) == null) {
        _view.selected = null;
        _wake();
      }
    }
  }

  void _setFilter(GalaxyFilter filter) {
    setState(() => _filter = filter);
    _view.update(filterScene(_full, filter), first: false);
    _wake();
  }

  void _select(String? id) {
    setState(() => _view.selected = id);
    _touch();
    final camera = _view.camera;
    if (id == null) {
      camera.overview();
      return;
    }
    final system = _view.scene.systemOf(id);
    final at = _view.positionOf(id);
    if (at == null) return;
    camera.focus(at, system != null ? 3.4 + system.extent * 1.6 : 2.6);
  }

  void _tap(Offset point) {
    _focus.requestFocus();
    _select(_view.hitAt(point)?.id);
  }

  void _hover(Offset point) {
    final id = _view.hitAt(point)?.id;
    if (id != _view.hovered) _mark(() => _view.hovered = id);
  }

  /// Change what is highlighted, and draw it.
  void _mark(VoidCallback change) {
    setState(change);
    _wake();
  }

  List<String> get _order => [
    for (final system in _view.scene.systems) ...[
      system.id,
      for (final planet in system.planets) planet.id,
    ],
  ];

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final order = _order;
    if (order.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final at = order.indexOf(_view.focused ?? _view.selected ?? '');
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown) {
      _mark(() => _view.focused = order[(at + 1) % order.length]);
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp) {
      _mark(
        () => _view.focused = order[(at - 1 + order.length) % order.length],
      );
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space) {
      _select(_view.focused ?? order.first);
    } else if (key == LogicalKeyboardKey.escape && _view.selected != null) {
      _select(null);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final overview = ref.watch(toolsOverviewProvider);
    final still = MediaQuery.disableAnimationsOf(context);
    if (still != _view.still) {
      _view.still = still;
      _wake();
    }
    if (!identical(overview, _source)) _rebuild(overview);
    // A screen reader gets the list unless the user chose the galaxy.
    final list = _list ?? MediaQuery.accessibleNavigationOf(context);
    if (list != _listShown) {
      _listShown = list;
      _wake();
    }
    final palette = GalaxyPalette(
      dark: theme.brightness == Brightness.dark,
      ratio: MediaQuery.devicePixelRatioOf(context),
      scheme: scheme,
      signal: infoColor(scheme),
      text: theme.textTheme.bodySmall ?? const TextStyle(),
    );
    final loaded =
        overview.thisDevice.isNotEmpty || overview.devices.isNotEmpty;
    final selected = _view.selected;
    return UtilityPage(
      route: '/galaxy',
      title: l10n.galaxyTitle,
      actions: [
        IconButton(
          key: const Key('galaxy-list-toggle'),
          tooltip: list ? l10n.galaxyTitle : l10n.galaxyList,
          icon: Icon(list ? AppIcons.orbit : AppIcons.list),
          onPressed: () => setState(() => _list = !list),
        ),
      ],
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 720;
          final canvas = constraints.biggest;
          if (canvas != _canvas) {
            _canvas = canvas;
            if (!_first) _refit(entrance: false);
          }
          final sky = Semantics(
            label: l10n.galaxyTitle,
            child: Focus(
              focusNode: _focus,
              onKeyEvent: _key,
              child: Listener(
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    _view.camera.zoom(
                      event.scrollDelta.dy < 0 ? 1.12 : 1 / 1.12,
                    );
                    _touch();
                  }
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: (_) {
                    _pinch = 1;
                    _view.camera.spin = 0;
                    _touch();
                  },
                  onScaleUpdate: (details) {
                    if (details.pointerCount > 1) {
                      _view.camera.zoom(details.scale / _pinch);
                      _pinch = details.scale;
                    }
                    _view.camera.drag(
                      details.focalPointDelta.dx,
                      details.focalPointDelta.dy,
                    );
                    _touch();
                  },
                  onScaleEnd: (details) {
                    _view.camera.spin =
                        -details.velocity.pixelsPerSecond.dx * 0.004;
                    _touch();
                  },
                  onTapUp: (details) => _tap(details.localPosition),
                  child: MouseRegion(
                    cursor: _view.hovered == null
                        ? SystemMouseCursors.grab
                        : SystemMouseCursors.click,
                    onHover: (event) => _hover(event.localPosition),
                    onExit: (_) => _mark(() => _view.hovered = null),
                    child: RepaintBoundary(
                      child: CustomPaint(
                        key: const Key('galaxy-canvas'),
                        size: Size.infinite,
                        painter: GalaxyPainter(
                          view: _view,
                          palette: palette,
                          l10n: l10n,
                          labels: _labels,
                          geometry: _geometry,
                          sprites: _sprites,
                          starfield: _stars,
                          onBackdrop: _backdropReady,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          final below = 12 + _barHeight;
          return ClipRect(
            child: Stack(
              children: [
                Positioned.fill(child: sky),
                if (list)
                  Positioned.fill(
                    child: Material(
                      color: theme.scaffoldBackgroundColor.withValues(
                        alpha: 0.86,
                      ),
                      child: GalaxyList(
                        top: below + 12,
                        scene: _view.scene,
                        onPick: (id) {
                          setState(() => _list = false);
                          _select(id);
                        },
                      ),
                    ),
                  ),
                if (loaded && overview.devices.isEmpty && !list)
                  Center(
                    child: Text(
                      l10n.galaxyEmpty,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: HeightReporter(
                        onHeight: (height) {
                          if (mounted && height != _barHeight) {
                            setState(() => _barHeight = height);
                          }
                        },
                        child: _Bar(
                          search: _search,
                          filter: _filter,
                          wide: wide,
                          onFilter: _setFilter,
                        ),
                      ),
                    ),
                  ),
                ),
                if (!list && wide)
                  const Positioned(left: 18, bottom: 16, child: _Legend()),
                if (selected != null && !list)
                  Positioned(
                    top: wide ? below + 16 : null,
                    right: wide ? 16 : 8,
                    left: wide ? null : 8,
                    bottom: wide ? null : 8,
                    width: wide ? 360 : null,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: wide
                            ? constraints.maxHeight - below - 36
                            : constraints.maxHeight * 0.6,
                      ),
                      child: Glass(
                        key: ValueKey('galaxy-panel-$selected'),
                        depth: GlassDepth.overlay,
                        borderRadius: BorderRadius.circular(20),
                        child: GalaxyPanel(
                          scene: _view.scene,
                          id: selected,
                          onPick: _select,
                          onClose: () => _select(null),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Search, the kind filter and nothing else, on glass over the sky.
class _Bar extends StatelessWidget {
  const _Bar({
    required this.search,
    required this.filter,
    required this.wide,
    required this.onFilter,
  });

  final TextEditingController search;
  final GalaxyFilter filter;
  final bool wide;
  final ValueChanged<GalaxyFilter> onFilter;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final field = TextField(
      key: const Key('galaxy-search'),
      controller: search,
      onChanged: (query) =>
          onFilter(GalaxyFilter(query: query, kind: filter.kind)),
      decoration: InputDecoration(
        isDense: true,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        prefixIcon: Icon(
          AppIcons.search,
          size: 17,
          color: scheme.onSurfaceVariant,
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 34),
        hintText: l10n.galaxySearch,
      ),
    );
    final kinds = GlassSegmented<BodyKind?>(
      expand: false,
      height: 30,
      selected: filter.kind,
      onChanged: (kind) =>
          onFilter(GalaxyFilter(query: filter.query, kind: kind)),
      segments: [
        GlassSegment(value: null, label: l10n.galaxyAll),
        GlassSegment(value: BodyKind.agent, label: l10n.galaxyKindAgent),
        GlassSegment(value: BodyKind.api, label: 'API'),
        GlassSegment(value: BodyKind.port, label: l10n.galaxyKindPort),
      ],
    );
    return Glass(
      depth: GlassDepth.floating,
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
      child: wide
          ? LayoutBuilder(
              builder: (context, box) => Row(
                children: [
                  Expanded(child: field),
                  // Large text scrolls the kinds rather than squeezing search.
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: box.maxWidth * 0.64),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: kinds,
                    ),
                  ),
                ],
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                field,
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: kinds,
                ),
              ],
            ),
    );
  }
}

/// What the colours mean.
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget entry(String status) => Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlanetGlyph(color: statusColor(scheme, status), size: 16),
          const SizedBox(width: 4),
          Text(
            statusLabel(l10n, status),
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
    return ExcludeSemantics(
      child: Glass(
        depth: GlassDepth.chrome,
        borderRadius: BorderRadius.circular(12),
        padding: const EdgeInsets.fromLTRB(10, 6, 0, 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            entry('online'),
            entry('starting'),
            entry('unreachable'),
            entry('offline'),
          ],
        ),
      ),
    );
  }
}
