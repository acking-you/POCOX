import 'support/native_diff_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/git_diff.dart';
import 'package:pocox/src/review/review_file_diff.dart';
import 'package:pocox/src/review/review_panel.dart';
import 'package:pocox/src/review/session_changes.dart';
import 'package:pocox/src/screens/app_session/transcript_model.dart';

Widget _host(Widget child, {Size size = const Size(900, 2000)}) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Center(
      child: SizedBox(width: size.width, height: size.height, child: child),
    ),
  ),
);

TranscriptItem _edit(String id, DiffModel diff) =>
    TranscriptItem(id: id, type: 'fileChange', diff: diff, turnId: 't-$id');

DiffModel _diffOf(String path, String old, String now) =>
    diffFixture(path, removed: [old], added: [now]);

SessionChanges _sessionFixture(List<TranscriptItem> items) {
  final edits = <SessionEdit>[];
  for (final item in items) {
    if (item.diff == null || item.diff!.isEmpty) continue;
    edits.add(
      SessionEdit(
        id: item.id,
        index: edits.length + 1,
        turnId: item.turnId,
        diff: item.diff!,
      ),
    );
  }
  final index = reviewIndexFixture(edits.map((e) => e.diff).toList());
  return SessionChanges(
    edits,
    [
      for (final file in index.files)
        SessionFile(
          file.path,
          [
            for (final s in file.sections)
              (edits[s.$1], edits[s.$1].diff.files[s.$2]),
          ],
          added: file.added,
          removed: file.removed,
        ),
    ],
    added: index.added,
    removed: index.removed,
  );
}

void main() {
  // A file changed at the top and again far down, so git emits two hunks with
  // an elided run between them (lines 4..49 unchanged).
  const twoHunks = DiffModel(
    [
      DiffFile(
        path: 'lib/x.dart',
        added: 2,
        removed: 1,
        lines: [
          DiffLine(
            DiffLineKind.hunk,
            '@@ -1,3 +1,3 @@',
            oldLine: 1,
            newLine: 1,
          ),
          DiffLine(DiffLineKind.context, 'line 1', oldLine: 1, newLine: 1),
          DiffLine(DiffLineKind.removed, 'line 2 old', oldLine: 2),
          DiffLine(DiffLineKind.added, 'line 2 new', newLine: 2),
          DiffLine(DiffLineKind.context, 'line 3', oldLine: 3, newLine: 3),
          DiffLine(
            DiffLineKind.hunk,
            '@@ -50,2 +50,3 @@',
            oldLine: 50,
            newLine: 50,
          ),
          DiffLine(DiffLineKind.context, 'line 50', oldLine: 50, newLine: 50),
          DiffLine(DiffLineKind.added, 'line 51 added', newLine: 51),
          DiffLine(DiffLineKind.context, 'line 52', oldLine: 51, newLine: 52),
        ],
      ),
    ],
    added: 2,
    removed: 1,
  );

  group('a workspace diff reads its elided lines in from the host', () {
    Future<void> pump(
      WidgetTester t,
      Future<List<String>?> Function(String)? load,
    ) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(900, 2000);
      addTearDown(t.view.reset);
      final file = twoHunks.files.single;
      await t.pumpWidget(
        _host(
          ReviewFileDiff(
            path: file.path,
            sections: [ReviewDiffSection(file: file, expandable: true)],
            onLoadFile: load,
          ),
        ),
      );
      await t.pumpAndSettle();
    }

    testWidgets('a gap expands once the file is read', (t) async {
      var loads = 0;
      await pump(t, (_) async {
        loads++;
        return [for (var i = 1; i <= 52; i++) 'line $i'];
      });
      expect(find.textContaining('line 30', findRichText: true), findsNothing);
      await t.tap(find.textContaining('行未更改'));
      await t.pumpAndSettle();
      expect(loads, 1);
      expect(
        find.textContaining('line 30', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('行未更改'), findsNothing);
    });

    testWidgets('a failed read says so and reveals nothing', (t) async {
      await pump(t, (_) async => null);
      await t.tap(find.textContaining('行未更改'));
      await t.pumpAndSettle();
      expect(find.textContaining('无法加载'), findsOneWidget);
      expect(find.textContaining('line 30', findRichText: true), findsNothing);
    });

    testWidgets('without a reader the gap is a plain marker', (t) async {
      await pump(t, null);
      await t.tap(find.textContaining('行未更改'));
      await t.pumpAndSettle();
      expect(find.textContaining('line 30', findRichText: true), findsNothing);
    });
  });

  group('the review', () {
    final session = _sessionFixture([
      _edit('e1', _diffOf('/proj/lib/a.dart', 'first', 'second')),
      _edit(
        'e2',
        combineDiffFixtures(
          _diffOf('/proj/lib/a.dart', 'second', 'third'),
          _diffOf('/proj/lib/b.dart', 'old b', 'new b'),
        ),
      ),
    ]);
    final workspace = _diffOf('lib/w.dart', 'was', 'is');

    Widget panel({
      ReviewTarget? target,
      double width = 520,
      Future<List<String>?> Function(String)? load,
      DiffModel? tree,
    }) => _host(
      ReviewPanel(
        session: session,
        workspace: tree ?? workspace,
        workspaceAvailable: true,
        root: '/proj',
        target: target,
        onLoadFile: load,
        onClose: () {},
      ),
      size: Size(width, 900),
    );

    testWidgets('opens on one edit, and widens to every edit of the file', (
      t,
    ) async {
      await t.pumpWidget(panel(target: const ReviewTarget(edit: 'e1')));
      await t.pumpAndSettle();
      // The edit touched one file, so it opens straight on its diff.
      expect(find.text('a.dart'), findsOneWidget);
      expect(find.textContaining('second', findRichText: true), findsWidgets);
      expect(find.textContaining('third', findRichText: true), findsNothing);
      expect(find.byKey(const Key('review-edit-filter')), findsOneWidget);
      // Clearing the edit shows each edit of the file as its own section.
      await t.tap(
        find.descendant(
          of: find.byKey(const Key('review-edit-filter')),
          matching: find.byIcon(AppIcons.close),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('第 1 次修改'), findsOneWidget);
      expect(find.text('第 2 次修改'), findsOneWidget);
      expect(find.textContaining('third', findRichText: true), findsWidgets);
    });

    testWidgets('a narrow review goes from list to file and back', (t) async {
      await t.pumpWidget(panel());
      await t.pumpAndSettle();
      // The workspace is the default where the host can diff it, and its one
      // file opens by itself.
      expect(find.text('w.dart'), findsOneWidget);
      await t.tap(find.byKey(const Key('review-source-session')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('review-file-/proj/lib/a.dart')), findsOne);
      expect(find.byKey(const Key('review-file-/proj/lib/b.dart')), findsOne);
      expect(find.text('2 次修改'), findsOneWidget);
      await t.tap(find.byKey(const Key('review-file-/proj/lib/b.dart')));
      await t.pumpAndSettle();
      expect(find.textContaining('new b', findRichText: true), findsWidgets);
      await t.tap(find.byKey(const Key('review-file-back')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('review-file-/proj/lib/a.dart')), findsOne);
    });

    testWidgets(
      'a working tree not read yet offers a retry, not "no changes"',
      (t) async {
        var refreshes = 0;
        await t.pumpWidget(
          _host(
            ReviewPanel(
              session: SessionChanges.empty,
              workspaceAvailable: true,
              onRefreshWorkspace: () async => refreshes++,
              onClose: () {},
            ),
            size: const Size(520, 900),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('与主分支相比没有变更。'), findsNothing);
        await t.tap(find.byKey(const Key('review-workspace-retry')));
        expect(refreshes, 1);
      },
    );

    testWidgets('a file opens whole, its changed lines marked', (t) async {
      await t.pumpWidget(
        panel(
          width: 900,
          load: (path) async => path == 'lib/w.dart' ? ['is', 'kept'] : null,
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('review-open-file')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('review-file-lines')), findsOneWidget);
      expect(find.textContaining('kept', findRichText: true), findsOneWidget);
    });

    testWidgets('a whole file is read again only when its diff changes', (
      t,
    ) async {
      var version = 1;
      var reads = 0;
      Future<List<String>?> load(String _) async {
        reads++;
        return ['version $version'];
      }

      await t.pumpWidget(panel(width: 900, load: load));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('review-open-file')));
      await t.pumpAndSettle();
      expect(find.textContaining('version 1', findRichText: true), findsOne);
      // The same diff, rebuilt: nothing to read again.
      await t.pumpWidget(panel(width: 900, load: load));
      await t.pumpAndSettle();
      expect(reads, 1);
      version = 2;
      final moved = _diffOf('lib/w.dart', 'was', 'now');
      await t.pumpWidget(panel(width: 900, load: load, tree: moved));
      await t.pumpAndSettle();
      expect(reads, 2);
      expect(find.textContaining('version 2', findRichText: true), findsOne);
    });

    testWidgets('a path named twice in the working tree keeps both records', (
      t,
    ) async {
      final tree = combineDiffFixtures(
        _diffOf('lib/w.dart', 'index old', 'index new'),
        _diffOf('lib/w.dart', 'tree old', 'tree new'),
      );
      await t.pumpWidget(panel(tree: tree));
      await t.pumpAndSettle();
      expect(find.textContaining('index new', findRichText: true), findsOne);
      expect(find.textContaining('tree new', findRichText: true), findsOne);
      expect(find.textContaining('+2', findRichText: true), findsWidgets);
    });
  });
}
