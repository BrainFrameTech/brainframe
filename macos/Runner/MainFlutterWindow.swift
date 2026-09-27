import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Picking and reaching folders outside the app's container. Held here so
  /// it lives as long as the window's engine.
  private var folderAccess: FolderAccessChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    folderAccess = FolderAccessChannel(
      registrar: flutterViewController.registrar(forPlugin: "FolderAccessChannel")
    )

    super.awakeFromNib()
  }
}

// MARK: - Folder access

/// The macOS side of `tech.brainframe.app/folder_access` — see
/// `lib/engram/channel_folder_access.dart` for the contract, and the sandboxed
/// folder adoption design (Decision 5) for why it is shaped this way.
///
/// **Written without a Mac to run it on:** designed-but-unverified until a
/// device run (the storage design's Decision 3). Manual test plan F40 is that
/// run.
///
/// The app is sandboxed, so a folder the user picks is reachable only for the
/// rest of that launch. An app-scoped bookmark (`.withSecurityScope`, allowed by
/// the `files.bookmarks.app-scope` entitlement) is what reaches it in a later
/// one; it is stored in the registry row and resolved at discovery. Once access
/// is started the URL's `path` is an ordinary path, so the Dart side reaches
/// the folder with `dart:io` as it always has on desktop. Access is held until
/// the process exits.
///
/// Kept in this file rather than its own so the Xcode project needs no new
/// source reference.
final class FolderAccessChannel: NSObject {
  private let channel: FlutterMethodChannel
  private weak var registrar: FlutterPluginRegistrar?

  /// Folders reachable now, by path: picked this launch (the panel's grant
  /// lasts until quit) or resolved with access started. Resolving one twice
  /// never starts access twice.
  private var accessed: [String: URL] = [:]

  init(registrar: FlutterPluginRegistrar) {
    channel = FlutterMethodChannel(
      name: "tech.brainframe.app/folder_access",
      binaryMessenger: registrar.messenger
    )
    self.registrar = registrar
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    // No permission gates folders on macOS: the open panel is the grant.
    case "hasBroadAccess", "requestBroadAccess": result(true)
    case "pick": pick(result)
    case "resolve": resolve(call.arguments as? [String: Any], result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func pick(_ result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    let answer: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .OK, let url = panel.url else {
        result(nil) // the user dismissed the panel
        return
      }
      self?.picked(url, result: result)
    }
    if let window = registrar?.view?.window {
      panel.beginSheetModal(for: window, completionHandler: answer)
    } else {
      panel.begin(completionHandler: answer)
    }
  }

  private func picked(_ url: URL, result: @escaping FlutterResult) {
    do {
      let bookmark = try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      accessed[url.path] = accessed[url.path] ?? url
      result(["path": url.path, "bookmark": bookmark.base64EncodedString()])
    } catch {
      result(FlutterError(code: "notLocal", message: error.localizedDescription, details: nil))
    }
  }

  /// A stored row back to a usable path: its bookmark resolved and access
  /// started. A row with no bookmark — adopted by a build from before
  /// bookmarks, when the sandbox refused the folder anyway — is one this
  /// platform cannot reach; adopting the folder again gives it one.
  private func resolve(_ arguments: [String: Any]?, result: @escaping FlutterResult) {
    guard let encoded = arguments?["bookmark"] as? String,
          let data = Data(base64Encoded: encoded) else {
      result(FlutterError(code: "bookmarkInvalid", message: "No bookmark stored for this folder.", details: nil))
      return
    }
    do {
      var stale = false
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
      guard startAccess(url) else {
        result(FlutterError(code: "bookmarkInvalid", message: "Access to \(url.path) was refused.", details: nil))
        return
      }
      var reply: [String: Any] = ["path": url.path]
      if stale,
         let fresh = try? url.bookmarkData(
           options: [.withSecurityScope],
           includingResourceValuesForKeys: nil,
           relativeTo: nil
         ) {
        reply["refreshedBookmark"] = fresh.base64EncodedString()
      }
      result(reply)
    } catch {
      result(FlutterError(code: "bookmarkInvalid", message: error.localizedDescription, details: nil))
    }
  }

  /// Starts security-scoped access to `url` unless it is already held;
  /// false if the folder cannot be reached.
  ///
  /// The system answers false for a URL that needs no scope at all — a folder
  /// inside this app's own container. That is not a refusal, so a false is
  /// taken at its word only if the folder cannot be read without it.
  private func startAccess(_ url: URL) -> Bool {
    if accessed[url.path] != nil { return true }
    if url.startAccessingSecurityScopedResource() {
      accessed[url.path] = url
      return true
    }
    return FileManager.default.isReadableFile(atPath: url.path)
  }
}
