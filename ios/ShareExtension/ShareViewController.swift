import UIKit
import UniformTypeIdentifiers

/// "Lucero Sync" in the iOS share sheet.
///
/// Copies whatever was shared (photos, videos, files, links, text) into the
/// App Group inbox as one batch with a manifest, then opens Lucero Sync, which
/// asks which device to send it to. Nothing leaves the phone from here.
final class ShareViewController: UIViewController {
  private let status = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var started = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor.black.withAlphaComponent(0.35)

    let card = UIView()
    card.backgroundColor = UIColor(red: 0.098, green: 0.078, blue: 0.059, alpha: 1)
    card.layer.cornerRadius = 22
    card.translatesAutoresizingMaskIntoConstraints = false

    let title = UILabel()
    title.text = "Lucero Sync"
    title.font = .systemFont(ofSize: 20, weight: .semibold)
    title.textColor = UIColor(red: 0.949, green: 0.910, blue: 0.847, alpha: 1)

    status.text = "Getting your items ready…"
    status.font = .systemFont(ofSize: 15)
    status.textColor = UIColor(red: 0.788, green: 0.733, blue: 0.647, alpha: 1)
    status.numberOfLines = 0
    status.textAlignment = .center

    spinner.color = UIColor(red: 1, green: 0.635, blue: 0.29, alpha: 1)
    spinner.startAnimating()

    let stack = UIStackView(arrangedSubviews: [title, spinner, status])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)
    view.addSubview(card)
    NSLayoutConstraint.activate([
      card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      card.widthAnchor.constraint(equalToConstant: 300),
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 26),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -26),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }
    started = true
    Task { await collect() }
  }

  // MARK: - Collecting

  private func collect() async {
    guard let inbox = AppGroup.inboxURL else {
      return fail("Open Lucero Sync once, then try sharing again.")
    }
    let batch = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
    } catch {
      return fail("Couldn't prepare the items: \(error.localizedDescription)")
    }

    var files: [String] = []
    var texts: [String] = []
    let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    for provider in providers {
      if let name = await copyFile(provider, into: batch) {
        files.append(name)
      } else if let url = await loadURL(provider) {
        texts.append(url.absoluteString)
      } else if let text = await loadText(provider) {
        texts.append(text)
      }
    }

    if files.isEmpty && texts.isEmpty {
      try? FileManager.default.removeItem(at: batch)
      return fail("There was nothing Lucero Sync could send.")
    }
    let manifest: [String: Any] = ["files": files, "texts": texts, "created": Date().timeIntervalSince1970]
    do {
      let data = try JSONSerialization.data(withJSONObject: manifest)
      // Written last: the app only picks up batches that have a manifest.
      try data.write(to: batch.appendingPathComponent("manifest.json"), options: .atomic)
    } catch {
      return fail("Couldn't prepare the items: \(error.localizedDescription)")
    }

    await MainActor.run {
      let n = files.count + texts.count
      status.text = "Opening Lucero Sync to send \(n) item\(n == 1 ? "" : "s")…"
      openHostApp()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        self.extensionContext?.completeRequest(returningItems: nil)
      }
    }
  }

  /// Files, photos and videos: copies the item's file into the batch folder.
  private func copyFile(_ provider: NSItemProvider, into folder: URL) async -> String? {
    let isPlainLink = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
      && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    let isPlainText = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
      && provider.registeredTypeIdentifiers.count == 1
    if isPlainLink || isPlainText { return nil }

    // Prefer the most specific media type the provider offers (keeps HEIC/RAW/MOV as-is).
    let preferred = provider.registeredTypeIdentifiers.first { id in
      guard let t = UTType(id) else { return false }
      return t.conforms(to: .image) || t.conforms(to: .movie) || t.conforms(to: .audio) || t.conforms(to: .data)
    } ?? UTType.data.identifier

    return await withCheckedContinuation { cont in
      provider.loadFileRepresentation(forTypeIdentifier: preferred) { url, _ in
        guard let url else { return cont.resume(returning: nil) }
        var name = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? (UTType(preferred)?.preferredFilenameExtension ?? "") : url.pathExtension
        if !ext.isEmpty && (name as NSString).pathExtension.isEmpty { name += ".\(ext)" }
        name = Self.safeName(name)
        var target = folder.appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
          let base = (name as NSString).deletingPathExtension
          let e = (name as NSString).pathExtension
          target = folder.appendingPathComponent(e.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(e)")
          n += 1
        }
        do {
          // The temporary file only lives until this handler returns.
          try FileManager.default.copyItem(at: url, to: target)
          cont.resume(returning: target.lastPathComponent)
        } catch {
          cont.resume(returning: nil)
        }
      }
    }
  }

  private func loadURL(_ provider: NSItemProvider) async -> URL? {
    guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return nil }
    return await withCheckedContinuation { cont in
      _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
    }
  }

  private func loadText(_ provider: NSItemProvider) async -> String? {
    guard provider.canLoadObject(ofClass: String.self) else { return nil }
    return await withCheckedContinuation { cont in
      _ = provider.loadObject(ofClass: String.self) { text, _ in
        cont.resume(returning: (text?.isEmpty ?? true) ? nil : text)
      }
    }
  }

  private static func safeName(_ raw: String) -> String {
    let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "_")
    let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return trimmed.isEmpty ? "file" : String(trimmed.prefix(180))
  }

  // MARK: - Finishing

  /// Share extensions can't call UIApplication.open (it's marked unavailable
  /// to extensions), so find the application object up the responder chain
  /// and send it openURL:options:completionHandler: through the runtime.
  private func openHostApp() {
    guard let url = URL(string: "lucerosync://share") else { return }
    let selector = NSSelectorFromString("openURL:options:completionHandler:")
    var responder: UIResponder? = self
    while let r = responder {
      if r.isKind(of: UIApplication.self), r.responds(to: selector) {
        typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let open = unsafeBitCast(r.method(for: selector), to: OpenURL.self)
        open(r, selector, url as NSURL, NSDictionary(), nil)
        return
      }
      responder = r.next
    }
  }

  private func fail(_ message: String) {
    Task { @MainActor in
      spinner.stopAnimating()
      status.text = message
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        self.extensionContext?.cancelRequest(withError: NSError(domain: "LuceroSync", code: 1))
      }
    }
  }
}
