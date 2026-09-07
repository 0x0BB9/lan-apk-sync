import Cocoa
import CoreImage
import CryptoKit
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var nativeChannel: FlutterMethodChannel?
  private var securityScopedURLs: [URL] = []

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

  deinit {
    for url in securityScopedURLs {
      url.stopAccessingSecurityScopedResource()
    }
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
      case "pickDirectory":
        self.pickDirectory(result: result)
      case "sha256":
        self.sha256(call: call, result: result)
      case "qrCode":
        self.qrCode(call: call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    nativeChannel = channel
  }

  private func pickApk(result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.title = "选择要同步的 APK"
    panel.prompt = "选择 APK"
    panel.allowedFileTypes = ["apk"]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.beginSheetModal(for: self) { [weak self] response in
      guard response == .OK, let url = panel.url else {
        result(nil)
        return
      }
      self?.retainAccess(to: url)
      result(url.path)
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
      self?.retainAccess(to: url)
      result(url.path)
    }
  }

  private func retainAccess(to url: URL) {
    if url.startAccessingSecurityScopedResource() {
      securityScopedURLs.append(url)
    }
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
