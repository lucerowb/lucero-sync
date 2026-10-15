import AVFoundation
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Open at a comfortable size, centred, and don't let it get too cramped.
    self.setContentSize(NSSize(width: 1180, height: 780))
    self.contentMinSize = NSSize(width: 420, height: 560)
    self.title = "Lucero Sync"
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    LuceroPermissions.register(with: flutterViewController.registrar(forPlugin: "LuceroPermissions"))

    super.awakeFromNib()
  }
}

/// Camera permission status and System Settings shortcuts for the
/// Settings › Permissions section.
class LuceroPermissions: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "lucero_sync/permissions", binaryMessenger: registrar.messenger)
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
    case "activateApp":
      NSApp.activate(ignoringOtherApps: true)
      result(nil)
    case "openSettings":
      // Privacy pane for the given section, e.g. "Camera", "Photos", "LocalNetwork".
      let pane = (call.arguments as? String) ?? "Photos"
      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
        NSWorkspace.shared.open(url)
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
