part of '../app_session_test.dart';

/// Image and file attachments: staging, retrying, sending and their history.
void _registerAttachments() {
  group('image attachments', () {
    late FakeImagePicker picker;
    setUp(() {
      // compute() spawns a real isolate whose completion never lands under the
      // fake test clock — run the processing pipeline inline instead.
      processImageImpl = (bytes) async => preparedImageFixture(bytes);
      picker = FakeImagePicker();
      ImagePickerPlatform.instance = picker;
    });
    tearDown(() {
      processImageImpl = processImageNative;
    });

    testWidgets('a failed image remains retryable without choosing it again', (
      t,
    ) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
      );
      const service = 'pcx:lb7666:app:default';
      await api.appConnect(service, 28080);
      await t.pumpWidget(
        host(const AppSessionScreen(serviceKey: service), api),
      );
      await t.pumpAndSettle();
      processImageImpl = (_) async =>
          throw StateError('decoder temporarily unavailable');
      picker.files = [MemXFile(tinyPng(), 'retry.png')];
      await attachMenu(t, 'attach-btn');
      await t.pumpAndSettle();
      expect(find.byKey(const Key('attachment-0')), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(
        t.widget<IconButton>(find.byKey(const Key('send-btn'))).onPressed,
        isNull,
      );
      processImageImpl = (bytes) async => preparedImageFixture(bytes);
      await t.tap(find.byKey(const Key('attachment-0')));
      await t.pumpAndSettle();
      expect(find.text('重试'), findsNothing);
      expect(
        t.widget<IconButton>(find.byKey(const Key('send-btn'))).onPressed,
        isNotNull,
      );
    });

    Future<FakeBridgeApi> pumpSession(
      WidgetTester t, {
      String? threadId,
    }) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect('pcx:lb7666:app:default', 28080);
      // Narrow so the sessions pane is a hidden drawer (single TextField).
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(400, 800);
      addTearDown(t.view.reset);
      await t.pumpWidget(
        host(
          AppSessionScreen(
            serviceKey: 'pcx:lb7666:app:default',
            threadId: threadId,
          ),
          api,
        ),
      );
      await t.pumpAndSettle();
      return api;
    }

    testWidgets('attach shows a preview chip; send carries data URLs and '
        'renders bubble thumbnails', (t) async {
      final api = await pumpSession(t);
      picker.files = [XFile.fromData(tinyPng(), name: 'shot.png')];

      await attachMenu(t, 'attach-btn');
      await t.pumpAndSettle();
      expect(find.byKey(const Key('attachment-0')), findsOneWidget);

      await t.enterText(find.byType(TextField), 'what is this?');
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pumpAndSettle();

      // The turn carried the processed image as a data URL…
      expect(api.lastTurnText, 'what is this?');
      expect(api.lastTurnImages, hasLength(1));
      expect(api.lastTurnImages.single, startsWith('data:image/png;base64,'));
      // …the optimistic bubble shows the thumbnail, and the composer strip
      // has been cleared for the next message.
      expect(find.byKey(const Key('msg-image-0')), findsOneWidget);
      expect(find.byKey(const Key('attachment-0')), findsNothing);
    });

    testWidgets('a sent message renders its image OUTSIDE the text bubble', (
      t,
    ) async {
      await pumpSession(t);
      picker.files = [XFile.fromData(tinyPng(), name: 'shot.png')];

      await attachMenu(t, 'attach-btn');
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'who is this?');
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pumpAndSettle();

      final thumb = find.byKey(const Key('msg-image-0'));
      expect(thumb, findsOneWidget);
      // `find.text` also matches the top-bar conversation title (it previews
      // the first message), so scope to the rendered body in the transcript.
      final body = find.descendant(
        of: find.byType(MarkdownView),
        matching: find.text('who is this?', findRichText: true),
      );
      expect(body, findsOneWidget);
      final bubble = find
          .ancestor(of: body, matching: find.byType(Container))
          .first;
      // The image is a sibling of the bubble, not a descendant: nesting it made
      // the picture inherit the bubble's padding and background, and left an
      // image-only message as a mostly-empty bubble.
      expect(
        find.descendant(of: bubble, matching: thumb),
        findsNothing,
        reason: 'thumbnail must not live inside the text bubble',
      );
      // And it sits ABOVE the text, matching the reference layout.
      expect(t.getCenter(thumb).dy, lessThan(t.getCenter(body).dy));
    });

    testWidgets('an image-only message can be sent (no text)', (t) async {
      final api = await pumpSession(t);
      picker.files = [XFile.fromData(tinyPng(), name: 'shot.png')];

      await attachMenu(t, 'attach-btn');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pumpAndSettle();

      expect(api.lastTurnText, '');
      expect(api.lastTurnImages, hasLength(1));
      expect(find.byKey(const Key('msg-image-0')), findsOneWidget);
    });

    testWidgets('a staged image opens the viewer before it is sent', (t) async {
      await pumpSession(t);
      picker.files = [
        XFile.fromData(tinyPng(), name: 'one.png'),
        XFile.fromData(tinyPng(), name: 'two.png'),
      ];

      await attachMenu(t, 'attach-btn');
      await t.pumpAndSettle();
      expect(find.byKey(const Key('attachment-0')), findsOneWidget);
      expect(find.byKey(const Key('attachment-1')), findsOneWidget);

      // Clicking the SECOND staged tile previews that one — checking what you
      // attached without having to send it first.
      await t.tap(find.byKey(const Key('attachment-1')));
      await t.pumpAndSettle();
      expect(find.byType(ImageViewerPage), findsOneWidget);
      // Both staged images are pageable, opened at the one clicked.
      expect(find.text('2/2'), findsOneWidget);

      // Closing returns to the composer with the attachments still staged.
      await t.tapAt(const Offset(40, 700));
      await t.pumpAndSettle();
      expect(find.byType(ImageViewerPage), findsNothing);
      expect(find.byKey(const Key('attachment-0')), findsOneWidget);
      expect(find.byKey(const Key('attachment-1')), findsOneWidget);
    });

    testWidgets('removing the pending attachment disables an image-only send', (
      t,
    ) async {
      await pumpSession(t);
      picker.files = [XFile.fromData(tinyPng(), name: 'shot.png')];

      await attachMenu(t, 'attach-btn');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('attachment-remove-0')));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('attachment-0')), findsNothing);
      final btn = t.widget<IconButton>(find.byKey(const Key('send-btn')));
      expect(btn.onPressed, isNull, reason: 'nothing left to send');
    });

    testWidgets('history restores image thumbnails and tap opens the '
        'fullscreen viewer', (t) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect('pcx:lb7666:app:default', 28080);
      api.readResult = ThreadHistory(
        items: [
          ThreadItem(
            id: 'u1',
            itemType: 'userMessage',
            title: '',
            text: 'look at this',
            images: [tinyPngDataUrl()],
          ),
        ],
        running: false,
      );
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(400, 800);
      addTearDown(t.view.reset);
      await t.pumpWidget(
        host(
          const AppSessionScreen(
            serviceKey: 'pcx:lb7666:app:default',
            threadId: 'thread-7',
          ),
          api,
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('look at this'), findsOneWidget);
      expect(find.byKey(const Key('msg-image-0')), findsOneWidget);

      await t.tap(find.byKey(const Key('msg-image-0')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('image-viewer-0')), findsOneWidget);
    });

    testWidgets('a host-only image (localImage path) renders a filename chip', (
      t,
    ) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect('pcx:lb7666:app:default', 28080);
      api.readResult = const ThreadHistory(
        items: [
          ThreadItem(
            id: 'u1',
            itemType: 'userMessage',
            title: '',
            text: '',
            images: ['/home/user/screenshots/error.png'],
          ),
        ],
        running: false,
      );
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(400, 800);
      addTearDown(t.view.reset);
      await t.pumpWidget(
        host(
          const AppSessionScreen(
            serviceKey: 'pcx:lb7666:app:default',
            threadId: 'thread-7',
          ),
          api,
        ),
      );
      await t.pumpAndSettle();

      // No pixels crossed the wire, and the host wouldn't serve the path — an
      // honest basename chip instead.
      expect(find.text('error.png'), findsOneWidget);
      expect(find.byKey(const Key('msg-image-0')), findsNothing);
    });

    testWidgets('a host image the host will serve renders as a thumbnail', (
      t,
    ) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect('pcx:lb7666:app:default', 28080);
      // Inside the project roots, so even a host too old for the
      // transcript-image route hands the bytes over.
      api.fileBytes['/proj/shot.png'] = onePixelPng;
      api.readResult = const ThreadHistory(
        items: [
          ThreadItem(
            id: 'u1',
            itemType: 'userMessage',
            title: '',
            text: '',
            images: ['/proj/shot.png'],
          ),
        ],
        running: false,
      );
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(400, 800);
      addTearDown(t.view.reset);
      await t.pumpWidget(
        host(
          const AppSessionScreen(
            serviceKey: 'pcx:lb7666:app:default',
            threadId: 'thread-8',
          ),
          api,
        ),
      );
      await t.pumpAndSettle();

      // The chip gave way to a real thumbnail, and it opens the viewer.
      expect(find.text('shot.png'), findsNothing);
      expect(find.byKey(const Key('msg-image-0')), findsOneWidget);
      await t.tap(find.byKey(const Key('msg-image-0')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('image-viewer-0')), findsOneWidget);
    });

    testWidgets('a temp-dir image the transcript references still renders', (
      t,
    ) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect('pcx:lb7666:app:default', 28080);
      // Outside every project root — `metaReadFile` refuses it (the fake
      // returns no bytes), but the host authorises it against the thread's
      // own transcript.
      const temp = 'C:/Users/u/AppData/Local/Temp/codex-clipboard-1.png';
      api.threadImageBytes[temp] = onePixelPng;
      api.readResult = const ThreadHistory(
        items: [
          ThreadItem(
            id: 'u1',
            itemType: 'userMessage',
            title: '',
            text:
                '# Files mentioned by the user:\n\n'
                '## codex-clipboard-1.png: $temp\n\n'
                '## My request for Codex:\n为什么仍然黑屏',
          ),
        ],
        running: false,
      );
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(400, 800);
      addTearDown(t.view.reset);
      await t.pumpWidget(
        host(
          const AppSessionScreen(
            serviceKey: 'pcx:lb7666:app:default',
            threadId: 'thread-9',
          ),
          api,
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('为什么仍然黑屏'), findsOneWidget);
      expect(find.byKey(const Key('msg-image-0')), findsOneWidget);
      expect(find.text('codex-clipboard-1.png'), findsNothing);
    });
  });

  group('file attachments', () {
    late FakeFileSelector selector;
    setUp(() {
      // Inline image processing (see the image-attachments group) — a picked
      // .png routes to the image pipeline even from the file picker.
      processImageImpl = (bytes) async => preparedImageFixture(bytes);
      selector = FakeFileSelector();
      fsel.FileSelectorPlatform.instance = selector;
    });
    tearDown(() {
      processImageImpl = processImageNative;
    });

    XFile tmpFile(String name, List<int> bytes) =>
        MemXFile(Uint8List.fromList(bytes), name);

    Future<FakeBridgeApi> pumpSession(WidgetTester t) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect('pcx:lb7666:app:default', 28080);
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(400, 800);
      addTearDown(t.view.reset);
      await t.pumpWidget(
        host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
      );
      await t.pumpAndSettle();
      return api;
    }

    testWidgets('a staged FILE has no preview (no pixels to show)', (t) async {
      await pumpSession(t);
      selector.files = [tmpFile('notes.txt', utf8.encode('x'))];

      await attachMenu(t, 'attach-file-btn');
      await t.pumpAndSettle();
      expect(find.byKey(const Key('attachment-0')), findsOneWidget);

      // Clicking it is inert: a document has no pixels, so there is nothing to
      // preview and the viewer must not open on an empty list.
      await t.tap(find.byKey(const Key('attachment-0')));
      await t.pumpAndSettle();
      expect(find.byType(ImageViewerPage), findsNothing);
    });

    testWidgets('attach uploads to the host and the turn text carries the '
        'path-reference block', (t) async {
      final api = await pumpSession(t);
      selector.files = [tmpFile('notes.txt', utf8.encode('sentinel-content'))];

      await attachMenu(t, 'attach-file-btn');
      await t.pumpAndSettle();
      // Uploaded chip shows the filename.
      expect(find.byKey(const Key('attachment-0')), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
      expect(api.lastUploadName, 'notes.txt');
      expect(utf8.decode(api.lastUploadBytes!), 'sentinel-content');

      await t.enterText(find.byType(TextField), 'check this');
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pumpAndSettle();

      // The wire text = typed text + the reference block with the HOST path.
      expect(
        api.lastTurnText,
        appendFileRefs('check this', ['/host/uploads/123/notes.txt']),
      );
      expect(api.lastTurnImages, isEmpty);
      // The bubble renders a chip + the typed text; the raw block is hidden.
      // (Two 'check this': the bubble and the top bar, which titles the
      // conversation with its preview.)
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('check this'), findsNWidgets(2));
      expect(find.textContaining(kAttachedFilesHeader), findsNothing);
      // Composer strip cleared.
      expect(find.byKey(const Key('attachment-0')), findsNothing);
    });

    testWidgets('a file-only message can be sent', (t) async {
      final api = await pumpSession(t);
      selector.files = [
        tmpFile('data.bin', [1, 2, 3]),
      ];
      await attachMenu(t, 'attach-file-btn');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pumpAndSettle();

      expect(
        api.lastTurnText,
        appendFileRefs('', ['/host/uploads/123/data.bin']),
      );
      expect(find.text('data.bin'), findsOneWidget); // bubble chip
    });

    testWidgets('a failed upload stays in the draft and can be retried', (
      t,
    ) async {
      final api = await pumpSession(t);
      api.uploadError = StateError('relay down');
      selector.files = [
        tmpFile('x.log', [9]),
      ];
      await attachMenu(t, 'attach-file-btn');
      await t.pumpAndSettle();

      expect(find.byKey(const Key('attachment-0')), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      // The failed attachment must not silently disappear from a send.
      final btn = t.widget<IconButton>(find.byKey(const Key('send-btn')));
      expect(btn.onPressed, isNull);
      api.uploadError = null;
      await t.tap(find.byKey(const Key('attachment-0')));
      await t.pumpAndSettle();
      expect(api.lastUploadName, 'x.log');
      expect(find.text('重试'), findsNothing);
      expect(
        t.widget<IconButton>(find.byKey(const Key('send-btn'))).onPressed,
        isNotNull,
      );
    });

    testWidgets('an image picked through the FILE picker routes to the image '
        'pipeline', (t) async {
      final api = await pumpSession(t);
      selector.files = [tmpFile('shot.png', tinyPng())];
      await attachMenu(t, 'attach-file-btn');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pumpAndSettle();

      expect(api.lastTurnImages, hasLength(1));
      expect(api.lastTurnImages.single, startsWith('data:image/png;base64,'));
      expect(api.lastUploadName, isNull, reason: 'images are not uploaded');
      expect(api.lastTurnText, isEmpty);
    });

    testWidgets('history restores document chips from the reference block', (
      t,
    ) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect('pcx:lb7666:app:default', 28080);
      api.readResult = ThreadHistory(
        items: [
          ThreadItem(
            id: 'u1',
            itemType: 'userMessage',
            title: '',
            text: appendFileRefs('review it', ['/host/uploads/9/report.pdf']),
          ),
        ],
        running: false,
      );
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(400, 800);
      addTearDown(t.view.reset);
      await t.pumpWidget(
        host(
          const AppSessionScreen(
            serviceKey: 'pcx:lb7666:app:default',
            threadId: 'thread-7',
          ),
          api,
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('report.pdf'), findsOneWidget); // chip label
      expect(find.text('review it'), findsOneWidget); // typed text
      expect(find.textContaining(kAttachedFilesHeader), findsNothing);
    });
  });
}
