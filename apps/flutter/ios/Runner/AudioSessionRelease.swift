import AVFoundation
import WebRTC

/// Hands the audio session back when WebRTC stops using audio.
///
/// On devices WebRTC plays and records through an AVAudioEngine. Starting the
/// engine activates the app's audio session, which interrupts other apps, but
/// nothing deactivates it again: music stopped by a call or a dictation take
/// stayed stopped while Pocket Codex was open. This observer deactivates the
/// session, telling the interrupted apps they may resume, once the engine is
/// fully disabled. The release waits a moment, so an engine that is only being
/// reconfigured (disabled and enabled again at once) keeps its session.
///
/// It changes nothing else: every other callback lets the engine proceed as
/// it would without an observer.
final class AudioSessionRelease: NSObject, RTCAudioDeviceModuleDelegate {
  static let shared = AudioSessionRelease()

  private let queue = DispatchQueue(label: "pocket_codex.audio_session")
  // Bumped by every engine start and every release request; a pending release
  // only runs if it is still the latest. Guarded by `queue`.
  private var generation = 0

  /// An engine about to run needs the session, so no pending release may run.
  /// Synchronous: a release under way finishes before the engine starts and
  /// the system activates the session again.
  private func engineWillRun() {
    queue.sync { generation &+= 1 }
  }

  func audioDeviceModule(
    _ audioDeviceModule: RTCAudioDeviceModule,
    willEnableEngine engine: AVAudioEngine,
    isPlayoutEnabled: Bool,
    isRecordingEnabled: Bool,
    isVoiceProcessingEnabled: Bool
  ) -> Int {
    engineWillRun()
    return 0
  }

  func audioDeviceModule(
    _ audioDeviceModule: RTCAudioDeviceModule,
    willStartEngine engine: AVAudioEngine,
    isPlayoutEnabled: Bool,
    isRecordingEnabled: Bool
  ) -> Int {
    engineWillRun()
    return 0
  }

  func audioDeviceModule(
    _ audioDeviceModule: RTCAudioDeviceModule,
    didDisableEngine engine: AVAudioEngine,
    isPlayoutEnabled: Bool,
    isRecordingEnabled: Bool
  ) -> Int {
    // A partial disable leaves the other direction running.
    guard !isPlayoutEnabled, !isRecordingEnabled else { return 0 }
    queue.async {
      self.generation &+= 1
      let ticket = self.generation
      self.queue.asyncAfter(deadline: .now() + 0.5) {
        guard ticket == self.generation else { return }
        try? AVAudioSession.sharedInstance().setActive(
          false,
          options: .notifyOthersOnDeactivation
        )
      }
    }
    return 0
  }

  func audioDeviceModule(
    _ audioDeviceModule: RTCAudioDeviceModule,
    didReceiveSpeechActivityEvent speechActivityEvent: RTCSpeechActivityEvent
  ) {}

  func audioDeviceModule(
    _ audioDeviceModule: RTCAudioDeviceModule,
    didCreateEngine engine: AVAudioEngine
  ) -> Int { 0 }

  func audioDeviceModule(
    _ audioDeviceModule: RTCAudioDeviceModule,
    didStopEngine engine: AVAudioEngine,
    isPlayoutEnabled: Bool,
    isRecordingEnabled: Bool
  ) -> Int { 0 }

  func audioDeviceModule(
    _ audioDeviceModule: RTCAudioDeviceModule,
    willReleaseEngine engine: AVAudioEngine
  ) -> Int { 0 }

  // Returning without connecting anything keeps the engine's own wiring.
  func audioDeviceModule(
    _ audioDeviceModule: RTCAudioDeviceModule,
    engine: AVAudioEngine,
    configureInputFromSource source: AVAudioNode?,
    toDestination destination: AVAudioNode,
    format: AVAudioFormat,
    context: [AnyHashable: Any]
  ) -> Int { 0 }

  func audioDeviceModule(
    _ audioDeviceModule: RTCAudioDeviceModule,
    engine: AVAudioEngine,
    configureOutputFromSource source: AVAudioNode,
    toDestination destination: AVAudioNode?,
    format: AVAudioFormat,
    context: [AnyHashable: Any]
  ) -> Int { 0 }

  func audioDeviceModuleDidUpdateDevices(_ audioDeviceModule: RTCAudioDeviceModule) {}
}
