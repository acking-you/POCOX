import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/project_index.dart';

const _remote = 'git@git.example.com:team/TSearchEngine.git';
const _main = '/Users/me/CLionProjects/new_tsearch/TSearchEngine';

ThreadMeta _thread(String cwd, [String? origin]) =>
    ThreadMeta(id: cwd, preview: '', cwd: cwd, originUrl: origin, updatedAt: 0);

void main() {
  test('Codex worktrees of a repository list under its own checkout', () {
    final index = ProjectIndex([
      _thread(_main, _remote),
      _thread('/Users/me/.codex/worktrees/fc39/TSearchEngine', _remote),
      // A reviewer recorded before its repository reported a remote.
      _thread('/Users/me/.codex/worktrees/b6a8/TSearchEngine'),
      _thread('$_main/docs', _remote),
      _thread('/Users/me/.codex/worktrees/0a1b/TSearchEngine/docs', _remote),
      _thread('/Users/me/other', 'git@git.example.com:team/other.git'),
    ]);
    expect(index.of('/Users/me/.codex/worktrees/fc39/TSearchEngine'), _main);
    expect(index.of('/Users/me/.codex/worktrees/b6a8/TSearchEngine'), _main);
    expect(
      index.of('/Users/me/.codex/worktrees/0a1b/TSearchEngine/docs'),
      '$_main/docs',
    );
    expect(index.of(_main), _main);
    expect(index.of('/Users/me/other'), '/Users/me/other');
  });

  test('without one matching checkout, worktrees share one project', () {
    const a = '/Users/me/.codex/worktrees/aaaa/app';
    const b = '/Users/me/.codex/worktrees/bbbb/app';
    // Another repository of the same name is not this one's checkout.
    final foreign = ProjectIndex([
      _thread(a, 'git@example.com:me/app.git'),
      _thread(b, 'git@example.com:me/app.git'),
      _thread('/Users/me/src/app', 'git@example.com:someone/app.git'),
    ]);
    expect(foreign.of(a), a);
    expect(foreign.of(b), a);
    expect(foreign.of('/Users/me/src/app'), '/Users/me/src/app');

    // Two checkouts that could both be the source: neither is chosen.
    final ambiguous = ProjectIndex([
      _thread(b),
      _thread('/Users/me/one/app'),
      _thread('/Users/me/two/app'),
    ]);
    expect(ambiguous.of(b), b);
  });
}
