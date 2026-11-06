import Flutter
import Foundation
import Security

/// The pairing device store's bytes, for the Rust engine (`pairingInstallNativeStore`).
///
/// Each record is a Keychain item readable after the first unlock, on this device only and
/// never synchronized, so neither iCloud Keychain nor a backup restored onto another phone
/// carries it. Keychain items usually outlive an uninstall, which is what lets a reinstall
/// keep its identity; Apple does not promise that. Records and slot names are opaque and
/// never logged: a record holds the device secret.
final class DeviceStoreChannel {
  private static let service = "io.github.acking-you.pocox.device-store"
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "pocox.device-store")

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "pocox/device_store", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "lockDir":
      result(Self.lockDirectory())
    case "hardwareId":
      // iOS offers no identifier that survives a reinstall for this.
      result(nil)
    case "read":
      guard let slot = arguments?["slot"] as? String, Self.isSlot(slot) else {
        result(["error": "not a device store slot"])
        return
      }
      queue.async {
        let answer = Self.read(slot)
        DispatchQueue.main.async { result(answer) }
      }
    case "write":
      guard let slot = arguments?["slot"] as? String, Self.isSlot(slot),
        let value = arguments?["value"] as? String
      else {
        result("not a device store record")
        return
      }
      queue.async {
        let failure = Self.write(slot, value)
        DispatchQueue.main.async { result(failure) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func isSlot(_ slot: String) -> Bool {
    !slot.isEmpty && slot.count <= 64
      && slot.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }

  private static func query(_ slot: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: slot,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    ]
  }

  /// The record, `value: nil` only when there is none. Anything else that stops it being
  /// read is an error, which never becomes a new device.
  private static func read(_ slot: String) -> [String: Any?] {
    var request = query(slot)
    request[kSecReturnData as String] = kCFBooleanTrue
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
        return ["error": "the device store holds unreadable bytes"]
      }
      return ["value": value]
    case errSecItemNotFound:
      return ["value": nil]
    default:
      return ["error": "the Keychain refused a read (status \(status))"]
    }
  }

  /// Replace the record; `nil` once the Keychain holds it.
  private static func write(_ slot: String, _ value: String) -> String? {
    let data = Data(value.utf8)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(query(slot) as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = query(slot)
      item.merge(attributes) { _, new in new }
      status = SecItemAdd(item as CFDictionary, nil)
    }
    return status == errSecSuccess ? nil : "the Keychain refused a write (status \(status))"
  }

  /// Where the engine keeps its lock files: app-private and out of backups.
  private static func lockDirectory() -> String? {
    guard
      var url = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { return nil }
    url.appendPathComponent("device-store-locks", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
    return url.path
  }
}
