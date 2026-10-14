import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Closing hides to the tray, so the app has to outlive its window.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Every native quit (Cmd+Q, the application menu, the Dock, an Apple
  /// Event, and `window_manager.destroy()` itself) arrives here. Replaces
  /// Flutter's default handler, which exits as soon as the framework agrees
  /// and would skip the hosted-service cleanup the Dart quit performs.
  override func applicationShouldTerminate(_ sender: NSApplication)
    -> NSApplication.TerminateReply
  {
    return NativeQuitGate.shared.shouldTerminate()
  }

  /// Bring the main window back when the app is reopened (Dock icon click,
  /// second launch — LaunchServices delivers both here).
  ///
  /// Deliberately ignores `hasVisibleWindows`: plugins (webview, drag & drop,
  /// the status item) own helper NSWindows that can count as "visible" while
  /// the real window is hidden to the tray, which would make a flag-guarded
  /// restore silently do nothing — the window could then never be reopened
  /// from the Dock. Restoring the main window unconditionally is also what a
  /// Dock click should do anyway. Targets MainFlutterWindow explicitly (never
  /// the helpers) and uses setIsVisible(true) first: makeKeyAndOrderFront
  /// alone does not reliably restore a window hidden via setIsVisible(false).
  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    let main =
      sender.windows.first { $0 is MainFlutterWindow }
      ?? sender.windows.first { $0.contentViewController is FlutterViewController }
    if let window = main {
      if window.isMiniaturized {
        window.deminiaturize(self)
      }
      window.setIsVisible(true)
      window.makeKeyAndOrderFront(self)
    }
    sender.activate(ignoringOtherApps: true)
    return false
  }
}

/// Routes native quit requests through the Dart quit
/// (`DesktopTray.quit`), which stops every hosted service first and keeps
/// the app open when that fails.
///
/// A native request is always cancelled and handed to Dart; the process
/// exits only after Dart approved it (`allowTerminate`) and terminated again
/// (`window_manager.destroy()`). A request that arrives before Dart is
/// listening is remembered and returned by Dart's `ready` call, so it is
/// neither dropped nor answered by exiting. `.terminateLater` is avoided:
/// AppKit then spins a modal run loop that the Flutter engine is not
/// guaranteed to service.
final class NativeQuitGate {
  static let shared = NativeQuitGate()

  private var channel: FlutterMethodChannel?
  /// Dart registered its handler and has not lost it since.
  private var dartReady = false
  /// A native quit Dart has not received yet.
  private var quitPending = false
  /// Dart finished its cleanup; the next terminate may exit.
  private var terminationApproved = false

  /// Binds the gate to the Flutter engine of the main window.
  func attach(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "pocket_codex/app_quit",
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "ready":
        // Hand over a quit that arrived before Dart was listening.
        self.dartReady = true
        let pending = self.quitPending
        self.quitPending = false
        result(pending)
      case "allowTerminate":
        self.terminationApproved = true
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  func shouldTerminate() -> NSApplication.TerminateReply {
    // Without an engine there is no Dart side that could own a service.
    if terminationApproved || channel == nil {
      return .terminateNow
    }
    quitPending = true
    if dartReady {
      deliverQuit()
    }
    return .terminateCancel
  }

  private func deliverQuit() {
    guard let channel = channel else { return }
    quitPending = false
    channel.invokeMethod("quit", arguments: nil) { [weak self] reply in
      // No handler (e.g. a restarting isolate): keep the request for the
      // next `ready` instead of losing it.
      if reply is FlutterError || (reply as AnyObject?) === FlutterMethodNotImplemented {
        self?.dartReady = false
        self?.quitPending = true
      }
    }
  }
}
