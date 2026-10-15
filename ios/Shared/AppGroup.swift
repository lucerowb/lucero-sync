import Foundation

/// The App Group shared by the app and its share extension.
///
/// AltStore and SideStore re-sign sideloaded apps and rename App Groups to
/// ones registered to the installer's team, then record the new names under
/// `ALTAppGroups` in Info.plist. So try those first, then the built-in name,
/// and use whichever group this build is actually entitled to.
enum AppGroup {
  static var containerURL: URL? {
    var candidates: [String] = []
    for bundle in [Bundle.main, hostAppBundle].compactMap({ $0 }) {
      candidates += (bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]) ?? []
      if let id = bundle.object(forInfoDictionaryKey: "AppGroupId") as? String { candidates.append(id) }
    }
    for id in candidates where !id.isEmpty && !id.contains("$(") {
      if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) { return url }
    }
    return nil
  }

  /// Where the share extension drops batches for the app to pick up.
  static var inboxURL: URL? { containerURL?.appendingPathComponent("Inbox", isDirectory: true) }

  /// From an extension, the containing app's bundle (two levels up from the .appex).
  private static var hostAppBundle: Bundle? {
    let url = Bundle.main.bundleURL
    guard url.pathExtension == "appex" else { return nil }
    return Bundle(url: url.deletingLastPathComponent().deletingLastPathComponent())
  }
}
