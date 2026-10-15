import ActivityKit
import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LuceroPermissions") {
      LuceroPermissions.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LuceroPlatform") {
      LuceroPlatform.register(with: registrar)
    }
  }
}

/// Camera permission status for the Settings › Permissions section
/// (permission_handler is only used on Android).
class LuceroPermissions: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "lucero_sync/permissions", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(LuceroPermissions(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "cameraStatus":
      result(Self.describe(AVCaptureDevice.authorizationStatus(for: .video)))
    case "requestCamera":
      AVCaptureDevice.requestAccess(for: .video) { _ in
        DispatchQueue.main.async { result(Self.describe(AVCaptureDevice.authorizationStatus(for: .video))) }
      }
    case "openSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func describe(_ s: AVAuthorizationStatus) -> String {
    switch s {
    case .authorized: return "granted"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
  }
}

/// Share-sheet inbox and Live Activity for the Dart side (`lucero_sync/platform`).
class LuceroPlatform: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "lucero_sync/platform", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(LuceroPlatform(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "takeSharedItems":
      result(Self.takeSharedItems())
    case "liveActivity":
      guard let args = call.arguments as? [String: Any] else { return result(nil) }
      if #available(iOS 16.2, *) {
        LiveActivityDriver.shared.apply(args)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Batches the share extension finished writing (they have a manifest).
  /// Returns [{files: [absolute paths], texts: [String]}] and forgets the
  /// manifests; the files stay until Dart cleans up old batches.
  static func takeSharedItems() -> [[String: Any]] {
    guard let inbox = AppGroup.inboxURL,
          let batches = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey])
    else { return [] }
    var out: [[String: Any]] = []
    for batch in batches.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let manifestURL = batch.appendingPathComponent("manifest.json")
      guard let data = try? Data(contentsOf: manifestURL),
            let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        // Abandoned half-written batch: drop it after a day.
        if let created = try? batch.resourceValues(forKeys: [.creationDateKey]).creationDate,
           Date().timeIntervalSince(created) > 86400 {
          try? FileManager.default.removeItem(at: batch)
        }
        continue
      }
      try? FileManager.default.removeItem(at: manifestURL)
      let files = ((m["files"] as? [String]) ?? []).map { batch.appendingPathComponent($0).path }
      out.append(["files": files, "texts": (m["texts"] as? [String]) ?? [], "folder": batch.path])
    }
    return out
  }
}

/// Starts, updates and ends the transfer Live Activity.
@available(iOS 16.2, *)
final class LiveActivityDriver {
  static let shared = LiveActivityDriver()
  private var activity: Activity<LuceroActivityAttributes>?

  func apply(_ args: [String: Any]) {
    let state = LuceroActivityAttributes.ContentState(
      headline: args["headline"] as? String ?? "Lucero Sync",
      detail: args["detail"] as? String ?? "",
      fraction: args["fraction"] as? Double ?? -1,
      count: args["count"] as? Int ?? 0,
      sending: args["sending"] as? Bool ?? true,
      finished: args["finished"] as? Bool ?? false
    )
    let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
    switch args["action"] as? String {
    case "update":
      if let activity {
        Task { await activity.update(content) }
      } else if ActivityAuthorizationInfo().areActivitiesEnabled {
        activity = try? Activity.request(
          attributes: LuceroActivityAttributes(deviceName: args["device"] as? String ?? ""),
          content: content)
      }
    case "end":
      guard let activity else { return }
      self.activity = nil
      Task { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(4))) }
    default:
      break
    }
  }
}
