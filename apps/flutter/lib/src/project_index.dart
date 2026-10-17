import 'package:pocket_codex/src/bridge_api.dart';

/// The project each conversation's folder belongs to.
///
/// Codex Desktop runs some conversations in managed worktrees, laid out as
/// `<worktree root>/<4 hex>/<repository>[/<subfolder>]` (the root is
/// `~/.codex/worktrees` unless configured). Such a checkout is the same
/// project as the repository it was made from, so it is listed under that
/// repository's own folder: the one known folder ending in the same
/// repository name and subfolder, of the same remote when both report one.
/// Without exactly one such folder, the worktrees of that repository share
/// one project instead of one per checkout. Every other folder is a project
/// of its own.
class ProjectIndex {
  /// Indexes the folders of [threads], newest first.
  factory ProjectIndex(Iterable<ThreadMeta> threads) {
    // Each folder once, in list order, with the first remote reported for it.
    final origins = <String, String?>{};
    for (final t in threads) {
      final cwd = t.cwd.trim();
      if (cwd.isEmpty) continue;
      origins[cwd] ??= t.originUrl;
    }
    final checkouts = [
      for (final cwd in origins.keys)
        if (!_managed.hasMatch(_normalized(cwd))) cwd,
    ];
    final aliases = <String, String>{};
    final shared = <String, String>{};
    for (final cwd in origins.keys) {
      final match = _managed.firstMatch(_normalized(cwd));
      if (match == null) continue;
      final tail = '/${match.group(1)!}';
      final origin = origins[cwd];
      final candidates = [
        for (final c in checkouts)
          if (_normalized(c).endsWith(tail) &&
              (origin == null || origins[c] == null || origins[c] == origin))
            c,
      ];
      final sameRemote = [
        for (final c in candidates)
          if (origin != null && origins[c] == origin) c,
      ];
      final source = sameRemote.length == 1
          ? sameRemote.single
          : candidates.length == 1
          ? candidates.single
          : null;
      aliases[cwd] = source ?? (shared['${origin ?? ''}\n$tail'] ??= cwd);
    }
    return ProjectIndex._(aliases);
  }

  const ProjectIndex._(this._aliases);

  /// An index that maps every folder to itself.
  static const empty = ProjectIndex._({});

  /// `<root>/worktrees/<bucket>/<repository>[/<subfolder>]`, capturing what
  /// follows the bucket.
  static final _managed = RegExp(r'^.*/worktrees/[0-9a-f]{4}/([^/]+(?:/.+)?)$');

  final Map<String, String> _aliases;

  /// The project folder [cwd] is listed under.
  String of(String cwd) {
    final folder = cwd.trim();
    return _aliases[folder] ?? folder;
  }

  static String _normalized(String path) {
    var p = path.replaceAll(r'\', '/');
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }
}
