import Flutter
import UIKit
import flutter_webrtc

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var deviceStore: DeviceStoreChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Before any WebRTC call creates the audio engine it observes.
    FlutterWebRTCPlugin.setAudioDeviceModuleObserver(AudioSessionRelease.shared)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PocoxDeviceStore") {
      deviceStore = DeviceStoreChannel(messenger: registrar.messenger())
    }
  }
}
