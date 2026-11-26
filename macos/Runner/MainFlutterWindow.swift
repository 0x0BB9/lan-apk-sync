import Cocoa
import CoreImage
import CryptoKit
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var nativeChannel: FlutterMethodChannel?
  private let preferences = SharingPreferences()

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = frame
    contentViewController = flutterViewController
    setFrame(windowFrame, display: true)
    minSize = NSSize(width: 880, height: 680)
    title = "LAN APK Sync"

    RegisterGeneratedPlugins(registry: flutterViewController)
    configureNativeChannel(flutterViewController)

    super.awakeFromNib()
  }

  private func configureNativeChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "io.github.0x0bb9.lan_apk_sync/native",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "window_closed", message: "Window closed.", details: nil))
        return
      }
      switch call.method {
      case "pickApk":
        self.pickApk(result: result)
      case "pickApks":
        self.pickApk(multiple: true, result: result)
      case "pickDirectory":
        self.pickDirectory(result: result)
      case "loadSettings":
        self.loadSettings(result: result)
      case "saveSettings":
        self.saveSettings(call: call, result: result)
      case "sha256":
        self.sha256(call: call, result: result)
      case "qrCode":
        self.qrCode(call: call, result: result)
      case "pathId":
        guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
          result(FlutterError(code: "bad_path", message: "Missing path.", details: nil))
          return
        }
        result(SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined())
      case "removeSource", "removeApk":
        guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
          result(FlutterError(code: "bad_path", message: "Missing path.", details: nil))
          return
        }
        self.preferences.removeSource(path: path, excludeApk: call.method == "removeApk")
        result(self.preferences.load())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    nativeChannel = channel
  }

  private func pickApk(multiple: Bool = false, result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.title = "选择要同步的 APK"
    panel.prompt = "添加 APK"
    panel.allowedFileTypes = ["apk"]
    panel.allowsMultipleSelection = multiple
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.beginSheetModal(for: self) { [weak self] response in
      guard response == .OK, !panel.urls.isEmpty else {
        result(nil)
        return
      }
      do {
        try self?.preferences.rememberSources(panel.urls, kind: "file")
        result(multiple ? panel.urls.map { $0.path } : panel.urls.first!.path)
      } catch {
        result(FlutterError(code: "bookmark_failed", message: "无法保存 APK 访问权限，请重新添加。", details: nil))
      }
    }
  }

  private func pickDirectory(result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.title = "选择 APK 构建输出目录"
    panel.prompt = "监听此目录"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.beginSheetModal(for: self) { [weak self] response in
      guard response == .OK, let url = panel.url else {
        result(nil)
        return
      }
      self?.rememberSource(url, kind: "directory", result: result)
    }
  }

  private func rememberSource(_ url: URL, kind: String, result: @escaping FlutterResult) {
    do {
      try preferences.rememberSource(url, kind: kind)
      result(url.path)
    } catch {
      result(FlutterError(
        code: "bookmark_failed",
        message: "无法保存文件访问权限，请重新选择 APK 或目录。",
        details: nil
      ))
    }
  }

  private func loadSettings(result: @escaping FlutterResult) {
    result(preferences.load())
  }

  private func saveSettings(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let token = arguments["token"] as? String,
          token.range(of: "^[A-Za-z0-9_-]{24}$", options: .regularExpression) != nil,
          let port = arguments["port"] as? Int,
          (1024...65535).contains(port),
          let autoStart = arguments["autoStart"] as? Bool else {
      result(FlutterError(code: "bad_settings", message: "无法保存同步设置。", details: nil))
      return
    }
    var settings: [String: Any] = ["token": token, "port": port, "autoStart": autoStart]
    if let address = arguments["preferredAddress"] as? String {
      settings["preferredAddress"] = address
    }
    // Preferences and security-scoped bookmarks stay in this Mac's app container.
    preferences.save(settings)
    result(nil)
  }

  private func sha256(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let path = arguments["path"] as? String
    else {
      result(FlutterError(code: "bad_arguments", message: "Missing APK path.", details: nil))
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
          let data = handle.readData(ofLength: 1024 * 1024)
          if data.isEmpty { break }
          hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        DispatchQueue.main.async { result(digest) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "hash_failed",
            message: "Unable to read the APK.",
            details: error.localizedDescription
          ))
        }
      }
    }
  }

  private func qrCode(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let value = arguments["value"] as? String,
      let data = value.data(using: .utf8),
      let filter = CIFilter(name: "CIQRCodeGenerator")
    else {
      result(FlutterError(code: "bad_arguments", message: "Missing QR value.", details: nil))
      return
    }

    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage?.transformed(
      by: CGAffineTransform(scaleX: 10, y: 10)
    ) else {
      result(FlutterError(code: "qr_failed", message: "Unable to create QR code.", details: nil))
      return
    }

    let context = CIContext(options: [.useSoftwareRenderer: false])
    guard let image = context.createCGImage(output, from: output.extent) else {
      result(FlutterError(code: "qr_failed", message: "Unable to render QR code.", details: nil))
      return
    }
    let representation = NSBitmapImageRep(cgImage: image)
    guard let png = representation.representation(using: .png, properties: [:]) else {
      result(FlutterError(code: "qr_failed", message: "Unable to encode QR code.", details: nil))
      return
    }
    result(FlutterStandardTypedData(bytes: png))
  }
}

final class SharingPreferences {
  private let defaults: UserDefaults
  private let settingsKey = "lanApkSync.settings"
  private let sourceKey = "lanApkSync.source"
  private let sourcesKey = "lanApkSync.sources"
  private let excludedKey = "lanApkSync.excludedPaths"
  private var securityScopedURLs: [URL] = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  deinit {
    for url in securityScopedURLs {
      url.stopAccessingSecurityScopedResource()
    }
  }

  func save(_ settings: [String: Any]) {
    defaults.set(settings, forKey: settingsKey)
  }

  func rememberSource(_ url: URL, kind: String) throws {
    try rememberSources([url], kind: kind)
  }

  private func storedSources() -> [[String: Any]] {
    if let sources = defaults.array(forKey: sourcesKey) as? [[String: Any]] { return sources }
    if let legacy = defaults.dictionary(forKey: sourceKey) { return [legacy] }
    return []
  }

  private func resolvedURL(_ source: [String: Any]) throws -> (URL, Bool) {
    guard let bookmark = source["bookmark"] as? Data else {
      throw NSError(domain: "LANApkSync", code: 1)
    }
    var stale = false
    let url = try URL(resolvingBookmarkData: bookmark,
                      options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                      bookmarkDataIsStale: &stale)
    return (url, stale)
  }

  func rememberSources(_ urls: [URL], kind: String) throws {
    // Prepare every bookmark first: cancelling/failing a multi-select is atomic.
    let additions: [[String: Any]] = try urls.map { url in
      let bookmark = try url.bookmarkData(
        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
        includingResourceValuesForKeys: nil, relativeTo: nil)
      return ["bookmark": bookmark, "kind": kind, "path": url.path]
    }
    var sources = storedSources()
    for (index, url) in urls.enumerated() {
      sources.removeAll { source in
        let path = source["path"] as? String ?? (try? resolvedURL(source).0.path)
        return path == url.path
      }
      sources.append(additions[index])
      retainAccess(to: url)
    }
    var excluded = defaults.stringArray(forKey: excludedKey) ?? []
    excluded.removeAll { path in urls.contains { url in
      path == url.path || (kind == "directory" && path.hasPrefix(url.path + "/"))
    } }
    defaults.set(excluded, forKey: excludedKey)
    defaults.set(sources, forKey: sourcesKey)
    defaults.removeObject(forKey: sourceKey)
  }

  func removeSource(path: String, excludeApk: Bool = false) {
    let sources = storedSources().filter { source in
      let storedPath = source["path"] as? String ?? (try? resolvedURL(source).0.path)
      return storedPath != path
    }
    defaults.set(sources, forKey: sourcesKey)
    defaults.removeObject(forKey: sourceKey)
    if excludeApk {
      var excluded = defaults.stringArray(forKey: excludedKey) ?? []
      if !excluded.contains(path) { excluded.append(path) }
      defaults.set(excluded, forKey: excludedKey)
    }
    // Keep already-open scopes until app exit, so active transfers can finish.
  }

  func load() -> [String: Any] {
    var settings = defaults.dictionary(forKey: settingsKey) ?? [:]
    var records = storedSources()
    var restored: [[String: String]] = []
    for index in records.indices {
      let source = records[index]
      do {
        guard let kind = source["kind"] as? String, kind == "file" || kind == "directory" else {
          throw NSError(domain: "LANApkSync", code: 2)
        }
        let (url, stale) = try resolvedURL(source)
        retainAccess(to: url)
        if stale {
          records[index]["bookmark"] = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        records[index]["path"] = url.path
        restored.append(["path": url.path, "kind": kind])
      } catch {
        settings["sourceError"] = "部分文件访问权限无法恢复，请重新添加对应 APK 或目录。其他 APK 可继续共享。"
      }
    }
    defaults.set(records, forKey: sourcesKey)
    defaults.removeObject(forKey: sourceKey)
    settings["sources"] = restored
    settings["excludedPaths"] = defaults.stringArray(forKey: excludedKey) ?? []
    // Retained for migration/test compatibility with single-source clients.
    settings["sourcePath"] = restored.first?["path"]
    settings["sourceKind"] = restored.first?["kind"]
    return settings
  }

  private func retainAccess(to url: URL) {
    if !securityScopedURLs.contains(url), url.startAccessingSecurityScopedResource() {
      securityScopedURLs.append(url)
    }
  }
}
