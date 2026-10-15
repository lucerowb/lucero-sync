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
