/// What the galaxy painter reads each frame, owned by the page: the scene,
/// the camera, the clock, what is selected or hovered, and the motion of
/// bodies that just appeared, changed or left.
library;

import 'package:flutter/material.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_camera.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_model.dart';

/// A body drawn this frame, for hit testing and labels.
class Hit {
  /// Creates a hit.
  const Hit(this.id, this.center, this.radius, this.depth, this.label);

  /// Body id (`device:<name>` or a service key).
  final String id;

  /// Where it is on screen.
  final Offset center;

  /// Its radius on screen.
  final double radius;

  /// Its distance from the camera.
  final double depth;

  /// Its name.
  final String label;
}

/// A body that left, fading where it was.
class Ghost {
  /// Creates a ghost.
  const Ghost(this.position, this.color, this.size, this.since);

  /// Last world position.
  final Vec3 position;

  /// Its colour.
  final Color color;

  /// Body radius in world units.
  final double size;

  /// When it left (scene seconds).
  final double since;
}

/// The page-owned state of the galaxy.
class GalaxyView extends ChangeNotifier {
  /// The scene drawn.
  GalaxyScene scene = GalaxyScene.empty;

  /// The camera.
  final GalaxyCamera camera = GalaxyCamera();

  /// Scene time in seconds.
  double time = 0;

  /// Whether motion is reduced (a still scene).
  bool still = false;

  /// The selected body.
  String? selected;

  /// The body under the pointer.
  String? hovered;

  /// The body with keyboard focus.
  String? focused;

  /// When each body appeared (it spirals out of its star).
  final Map<String, double> appeared = {};

  /// When each body's status last changed (a ripple crosses its ring).
  final Map<String, double> rippled = {};

  /// Bodies that just left.
  final List<Ghost> ghosts = [];

  /// Bodies drawn in the last frame, front last.
  List<Hit> hits = const [];

  /// Repaint.
  void tick() => notifyListeners();

  /// Take [next] as the scene, noting what appeared, changed or left.
  void update(GalaxyScene next, {required bool first}) {
    final before = <String, ({String status, Vec3 at, double size})>{};
    for (final system in scene.systems) {
      for (final planet in system.planets) {
        before[planet.id] = (
          status: planet.service.status,
          at: system.position + planet.offsetAt(time),
          size: planet.size,
        );
      }
    }
    final now = <String>{};
    for (final system in next.systems) {
      for (final planet in system.planets) {
        now.add(planet.id);
        final old = before[planet.id];
        if (old == null) {
          if (!first) appeared[planet.id] = time;
        } else if (old.status != planet.service.status) {
          rippled[planet.id] = time;
        }
      }
    }
    for (final entry in before.entries) {
      if (!now.contains(entry.key) && !first) {
        ghosts.add(Ghost(entry.value.at, Colors.white, entry.value.size, time));
      }
    }
    scene = next;
    notifyListeners();
  }

  /// The world position of body [id] now, if it exists.
  Vec3? positionOf(String id) {
    for (final system in scene.systems) {
      if (system.id == id) return system.position;
      for (final planet in system.planets) {
        if (planet.id == id) return system.position + planet.offsetAt(time);
      }
    }
    return null;
  }

  /// The front-most body within reach of [point].
  Hit? hitAt(Offset point) {
    Hit? best;
    for (final hit in hits) {
      final reach = hit.radius + 12 < 22 ? 22 : hit.radius + 12;
      if ((hit.center - point).distance <= reach &&
          (best == null || hit.depth < best.depth)) {
        best = hit;
      }
    }
    return best;
  }
}
