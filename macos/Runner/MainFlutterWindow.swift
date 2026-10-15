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

    super.awakeFromNib()
  }
}
