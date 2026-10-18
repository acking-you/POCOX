/// Where the galaxy is seen from: a camera orbiting a target on the disk, in
/// true perspective, easing smoothly between framings.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:pocket_codex/src/tools/galaxy/galaxy_model.dart';

/// One projected point.
typedef Projected = ({Offset point, double scale, double depth});

/// The view of one frame: world points to screen points.
class Projection {
  /// Creates a projection.
  Projection({
    required this.eye,
    required Vec3 target,
    required this.center,
    required this.focal,
  }) : forward = (target - eye).unit,
       right = (target - eye).unit.cross(const Vec3(0, 1, 0)).unit,
       up = (target - eye).unit
           .cross(const Vec3(0, 1, 0))
           .unit
           .cross((target - eye).unit);

  /// Camera position.
  final Vec3 eye;

  /// Viewing direction.
  final Vec3 forward;

  /// Screen right in the world.
  final Vec3 right;

  /// Screen up in the world.
  final Vec3 up;

  /// Screen centre.
  final Offset center;

  /// Focal length in pixels.
  final double focal;

  /// [p] on screen, or null behind the camera.
  Projected? at(Vec3 p) {
    final v = p - eye;
    final depth = v.dot(forward);
    if (depth < 0.2) return null;
    final s = focal / depth;
    return (
      point: Offset(center.dx + v.dot(right) * s, center.dy - v.dot(up) * s),
      scale: s,
      depth: depth,
    );
  }
}

/// The camera, with targets it eases towards.
class GalaxyCamera {
  /// Turn of the disk around its axis, in radians.
  double yaw = 0.6;

  /// Elevation above the disk plane, in radians.
  double tilt = _defaultTilt;

  /// Distance from the target.
  double distance = 12;

  /// What it looks at.
  Vec3 target = Vec3.zero;

  /// Where each eases to.
  double goalTilt = _defaultTilt;

  /// Distance the camera eases to.
  double goalDistance = 12;

  /// Target the camera eases to.
  Vec3 goalTarget = Vec3.zero;

  /// Yaw speed from a drag, decaying.
  double spin = 0;

  /// The framing that shows every system.
  double fitDistance = 12;

  /// The resting elevation: about 30° above the plane, higher on a portrait
  /// screen so the disk fills its height.
  double restTilt = _defaultTilt;

  static const double _defaultTilt = 0.52;

  /// One turn every six minutes.
  static const double driftSpeed = math.pi * 2 / 360;

  /// Fit [radius] world units of disk on a canvas of [size]: the disk's
  /// width must fit across, its foreshortened depth up and down, with room
  /// for the near side, which perspective enlarges.
  void fit(double radius, Size size) {
    if (size.isEmpty) return;
    restTilt = size.height > size.width * 1.3 ? 0.82 : _defaultTilt;
    final focal = size.shortestSide * 0.92;
    // Systems may brush the edges as the disk turns past them.
    final across = radius * focal / (size.width * 0.55);
    final deep = radius * math.sin(restTilt) * focal / (size.height * 0.42);
    fitDistance = math.max(5.5, math.max(across, deep) + radius * 0.25 + 0.6);
  }

  /// Ease back to the whole galaxy.
  void overview() {
    goalTarget = Vec3.zero;
    goalDistance = fitDistance;
    goalTilt = restTilt;
  }

  /// Ease to frame [point] from [closeness] away.
  void focus(Vec3 point, double closeness) {
    goalTarget = point;
    goalDistance = closeness;
  }

  /// Drag by [dx], [dy] pixels.
  void drag(double dx, double dy) {
    yaw -= dx * 0.006;
    goalTilt = (goalTilt + dy * 0.004).clamp(0.16, 1.3);
    tilt = goalTilt;
  }

  /// Zoom by [factor] (above one: closer).
  void zoom(double factor) {
    goalDistance = (goalDistance / factor).clamp(2.2, fitDistance * 1.8);
  }

  /// Advance by [dt] seconds; [drifting] turns the disk slowly.
  void step(double dt, {required bool drifting}) {
    final ease = 1 - math.exp(-dt * 3.2);
    tilt += (goalTilt - tilt) * ease;
    distance += (goalDistance - distance) * ease;
    target = target.lerp(goalTarget, ease);
    yaw += spin * dt;
    spin *= math.exp(-dt * 2.4);
    if (spin.abs() < 0.002) spin = 0;
    if (drifting) yaw += driftSpeed * dt;
  }

  /// Whether it has arrived, to far below a pixel, and nothing turns it
  /// (drift aside).
  bool get settled =>
      spin == 0 &&
      (goalTilt - tilt).abs() < 1e-4 &&
      (goalDistance - distance).abs() < 1e-3 &&
      (goalTarget - target).length < 1e-3;

  /// This frame's projection for a canvas of [size].
  Projection project(Size size) {
    final eye =
        target +
        Vec3(
              math.cos(tilt) * math.sin(yaw),
              math.sin(tilt),
              math.cos(tilt) * math.cos(yaw),
            ) *
            distance;
    return Projection(
      eye: eye,
      target: target,
      center: Offset(size.width / 2, size.height * 0.52),
      focal: size.shortestSide * 0.92,
    );
  }
}
