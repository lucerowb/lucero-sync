import ActivityKit
import Foundation

/// Live Activity (Lock Screen + Dynamic Island) for transfers in progress.
/// Compiled into both the app, which starts and updates it, and the widget
/// extension, which draws it.
@available(iOS 16.1, *)
struct LuceroActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    /// e.g. "Backup to Studio Mac" or "Sending 2, receiving 1".
    var headline: String
    /// e.g. "37 of 120" or "2.1 MB of 5 MB".
    var detail: String
    /// 0...1, or -1 when unknown.
    var fraction: Double
    var count: Int
    /// Mostly sending (arrow up) or receiving (arrow down).
    var sending: Bool
    var finished: Bool
  }

  var deviceName: String
}
