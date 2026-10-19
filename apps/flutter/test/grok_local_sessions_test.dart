// Grok Build's Local sessions: listed beside the other providers, and
// renamed or deleted here through Grok itself.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/local_sessions_screen.dart';

import 'fake_bridge_api.dart';

const _id = '01a15501-b678-7db0-b062-a1f5b1edc8d1';

LocalSession _row(String title) => LocalSession(
  threadId: _id,
  cwd: '/work/project',
  preview: title,
  source: 'grok',
  updatedAt: 0,
  turnState: 'unknown',
  heldOpen: false,
  safety: 'unknown',
  allowsResume: false,
  requiresTakeover: false,
);

Future<void> _pump(WidgetTester t, FakeBridgeApi api) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [bridgeApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const LocalSessionsScreen(
          source: SessionSource.local(provider: 'grok'),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> _menu(WidgetTester t, String item) async {
  await t.tap(find.byKey(const Key('native-manage-$_id')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(Key(item)));
  await t.pumpAndSettle();
}

/// [body] on a desktop, where Local sessions read this computer's files.
void _desktop(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(name, (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await body(t);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

void main() {
  _desktop('a Grok session is renamed and deleted through Grok', (t) async {
    final api = FakeBridgeApi();
    api.nativeSessions['grok'] = [_row('First prompt')];
    await _pump(t, api);
    expect(find.byKey(const Key('local-provider-grok')), findsOneWidget);
    expect(find.text('First prompt'), findsOneWidget);

    await _menu(t, 'native-rename');
    await t.enterText(find.byKey(const Key('native-rename-field')), 'Release');
    await t.tap(find.byKey(const Key('native-rename-save')));
    await t.pumpAndSettle();
    expect(api.nativeRenames, [('grok', _id, 'Release')]);
    expect(find.text('Release'), findsOneWidget, reason: 'listed again');

    // Deleting asks first; cancelling deletes nothing.
    await _menu(t, 'native-delete');
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(api.nativeDeletes, isEmpty);
    await _menu(t, 'native-delete');
    await t.tap(find.byKey(const Key('native-delete-confirm')));
    await t.pumpAndSettle();
    expect(api.nativeDeletes, [('grok', _id)]);
    expect(find.text('Release'), findsNothing);
  });

  _desktop('a refused change keeps the session and says why', (t) async {
    final api = FakeBridgeApi()
      ..nativeManageError = Exception(
        'Grok has this session open; close it there first',
      );
    api.nativeSessions['grok'] = [_row('Held')];
    await _pump(t, api);
    await _menu(t, 'native-delete');
    await t.tap(find.byKey(const Key('native-delete-confirm')));
    await t.pump();
    expect(find.textContaining('close it there first'), findsOneWidget);
    expect(find.text('Held'), findsOneWidget);
    await t.pumpAndSettle(const Duration(seconds: 5));
  });

  _desktop('a read-only source offers no rename or delete', (t) async {
    final api = FakeBridgeApi();
    api.nativeSessions['claude'] = [_row('Claude chat')];
    await t.pumpWidget(
      ProviderScope(
        overrides: [bridgeApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const LocalSessionsScreen(
            source: SessionSource.local(provider: 'claude'),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Claude chat'), findsOneWidget);
    expect(find.byKey(const Key('native-manage-$_id')), findsNothing);
  });
}
