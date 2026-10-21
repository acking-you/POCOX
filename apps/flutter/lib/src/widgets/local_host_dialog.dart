import 'package:pocox/src/hosting/host_editor_page.dart';

export 'package:pocox/src/hosting/host_editor_page.dart'
    show HostingEditor, showHostingEditor;

/// The former hosting dialog, now the full-page [HostingEditor]; the name is
/// kept so existing imports and finders keep working.
typedef LocalHostDialog = HostingEditor;
