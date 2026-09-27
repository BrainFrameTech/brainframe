import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Picking and reaching folders outside the app's container. Held here so
  /// it lives as long as the engine it answers for.
  private var folderAccess: FolderAccessChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FolderAccessChannel") {
      folderAccess = FolderAccessChannel(registrar: registrar)
    }
  }
}

// MARK: - Folder access

/// The iOS side of `tech.brainframe.app/folder_access` — see
/// `lib/engram/channel_folder_access.dart` for the contract, and the sandboxed
/// folder adoption design (Decision 5) for why it is shaped this way.
///
/// **Written without an iPhone to run it on:** designed-but-unverified until a
/// device run (the storage design's Decision 3). Manual test plan F40 is that
/// run.
///
/// A folder picked in the document picker arrives as a security-scoped URL.
/// Once access is started its `path` is an ordinary path, so the Dart side
/// reaches the folder with `dart:io` as on any desktop; the only work here is
/// getting that access back in a later launch, which is what the bookmark
/// stored in the registry row is for. Access is held until the process exits
/// rather than released on every switch: discovery, the switcher and a later
/// switch all read the folders, and the system's cap on concurrently accessed
/// resources is far above any real number of adopted engrams.
///
/// Kept in this file rather than its own so the Xcode project needs no new
/// source reference.
final class FolderAccessChannel: NSObject, UIDocumentPickerDelegate {
  private let channel: FlutterMethodChannel
  private weak var registrar: FlutterPluginRegistrar?

  /// The `pick` call waiting for the document picker to answer.
  private var pendingPick: FlutterResult?

  /// Folders whose security-scoped access is started, by path, so resolving
  /// one twice never starts it twice.
  private var accessed: [String: URL] = [:]

  init(registrar: FlutterPluginRegistrar) {
    channel = FlutterMethodChannel(
      name: "tech.brainframe.app/folder_access",
      binaryMessenger: registrar.messenger()
    )
    self.registrar = registrar
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    // No permission gates folders on iOS: the picker is the grant.
    case "hasBroadAccess", "requestBroadAccess": result(true)
    case "pick": pick(result)
    case "resolve": resolve(call.arguments as? [String: Any], result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func pick(_ result: @escaping FlutterResult) {
    guard pendingPick == nil else {
      result(FlutterError(code: "busy", message: "A folder picker is already open.", details: nil))
      return
    }
    guard let presenter = registrar?.viewController else {
      result(FlutterError(code: "noPicker", message: "No view to present the picker from.", details: nil))
      return
    }
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    } else {
      picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
    }
    picker.delegate = self
    picker.allowsMultipleSelection = false
    pendingPick = result
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pendingPick else { return }
    pendingPick = nil
    guard let url = urls.first else {
      result(nil)
      return
    }
    guard startAccess(url) else {
      result(FlutterError(code: "notLocal", message: "No access to \(url).", details: nil))
      return
    }
    do {
      let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
      result(["path": url.path, "bookmark": bookmark.base64EncodedString()])
    } catch {
      result(FlutterError(code: "notLocal", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingPick?(nil)
    pendingPick = nil
  }

  /// A stored row back to a usable path: its bookmark resolved and access
  /// started. A row with no bookmark is one this platform cannot reach —
  /// adopting the folder again gives it one.
  private func resolve(_ arguments: [String: Any]?, result: @escaping FlutterResult) {
    guard let encoded = arguments?["bookmark"] as? String,
          let data = Data(base64Encoded: encoded) else {
      result(FlutterError(code: "bookmarkInvalid", message: "No bookmark stored for this folder.", details: nil))
      return
    }
    do {
      var stale = false
      let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
      guard startAccess(url) else {
        result(FlutterError(code: "bookmarkInvalid", message: "Access to \(url.path) was refused.", details: nil))
        return
      }
      var reply: [String: Any] = ["path": url.path]
      if stale,
         let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
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
  /// inside this app's own container, which the Files app shows as
  /// *On My iPhone › BrainFrame* because the app shares its Documents
  /// directory. That is not a refusal, so a false is taken at its word only
  /// if the folder cannot be read without it.
  private func startAccess(_ url: URL) -> Bool {
    if accessed[url.path] != nil { return true }
    if url.startAccessingSecurityScopedResource() {
      accessed[url.path] = url
      return true
    }
    return FileManager.default.isReadableFile(atPath: url.path)
  }
}
