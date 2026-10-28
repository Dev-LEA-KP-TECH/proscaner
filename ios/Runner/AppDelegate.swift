import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// ช่อง proscaner/files (สำรอง/กู้คืนข้อมูล) ต้องเก็บไว้ตลอดอายุแอป
  private var files: ProScanerFiles?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ProScanerFiles") {
      files = ProScanerFiles(messenger: registrar.messenger())
    }
  }
}

/// บันทึกไฟล์ลงที่ที่ผู้ใช้เลือก / เปิดไฟล์ที่ผู้ใช้เลือก ผ่านหน้าต่าง "ไฟล์" ของ iOS
/// ใช้ช่องและชื่อคำสั่งเดียวกับฝั่ง Android (lib/data/file_port.dart):
/// - saveDocument {name, mime, bytes} -> ที่อยู่ไฟล์ที่บันทึก หรือ nil ถ้าผู้ใช้ยกเลิก
/// - openDocument {mimeTypes} -> ข้อมูลไฟล์ (bytes) หรือ nil ถ้าผู้ใช้ยกเลิก
final class ProScanerFiles: NSObject, UIDocumentPickerDelegate {
  private let channel: FlutterMethodChannel
  private var pending: FlutterResult?
  private var saving = false
  private var tempFile: URL?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "proscaner/files", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if pending != nil {
      result(FlutterError(code: "busy", message: "หน้าต่างเลือกไฟล์เปิดอยู่แล้ว", details: nil))
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "saveDocument":
      guard let name = args["name"] as? String,
            let typed = args["bytes"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "args", message: "ข้อมูลไฟล์ไม่ครบ", details: nil))
        return
      }
      let safeName = name.replacingOccurrences(of: "/", with: "_")
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
      do {
        try typed.data.write(to: url, options: .atomic)
      } catch {
        result(FlutterError(code: "write", message: "เตรียมไฟล์ไม่สำเร็จ", details: error.localizedDescription))
        return
      }
      let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
      present(picker, saving: true, temp: url, result: result)
    case "openDocument":
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText, .data], asCopy: true)
      picker.allowsMultipleSelection = false
      present(picker, saving: false, temp: nil, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func present(_ picker: UIDocumentPickerViewController, saving: Bool, temp: URL?, result: @escaping FlutterResult) {
    guard let top = ProScanerFiles.topViewController() else {
      if let temp = temp { try? FileManager.default.removeItem(at: temp) }
      result(FlutterError(code: "ui", message: "เปิดหน้าต่างเลือกไฟล์ไม่ได้", details: nil))
      return
    }
    picker.delegate = self
    self.saving = saving
    self.tempFile = temp
    self.pending = result
    top.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pending else { return }
    pending = nil
    defer { cleanup() }
    if saving {
      result(urls.first?.absoluteString ?? "")
      return
    }
    guard let url = urls.first else {
      result(nil)
      return
    }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let data = try Data(contentsOf: url)
      result(FlutterStandardTypedData(bytes: data))
    } catch {
      result(FlutterError(code: "read", message: "อ่านไฟล์ไม่สำเร็จ", details: error.localizedDescription))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = pending
    pending = nil
    cleanup()
    result?(nil)
  }

  private func cleanup() {
    if let temp = tempFile { try? FileManager.default.removeItem(at: temp) }
    tempFile = nil
  }

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
