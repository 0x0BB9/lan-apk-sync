import Cocoa
import FlutterMacOS
import XCTest
@testable import LAN_APK_Sync

class RunnerTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    suiteName = "lan-apk-sync-tests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
  }

  func testSettingsSurviveAStoreRecreation() {
    let original = SharingPreferences(defaults: defaults)
    original.save(["token": String(repeating: "a", count: 24), "port": 8888, "autoStart": true])

    let restored = SharingPreferences(defaults: defaults).load()
    XCTAssertEqual(restored["token"] as? String, String(repeating: "a", count: 24))
    XCTAssertEqual(restored["port"] as? Int, 8888)
    XCTAssertEqual(restored["autoStart"] as? Bool, true)
  }

  func testDirectoryBookmarkSurvivesAStoreRecreation() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("lan-apk-bookmark-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var original: SharingPreferences? = SharingPreferences(defaults: defaults)
    try original?.rememberSource(directory, kind: "directory")
    original = nil

    let restored = SharingPreferences(defaults: defaults).load()
    let path = try XCTUnwrap(restored["sourcePath"] as? String)
    XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
    XCTAssertEqual(restored["sourceKind"] as? String, "directory")
    XCTAssertNil(restored["sourceError"])
  }

  func testBrokenBookmarkDoesNotDiscardTheSavedLink() {
    let preferences = SharingPreferences(defaults: defaults)
    preferences.save(["token": String(repeating: "b", count: 24)])
    defaults.set(["bookmark": Data([0, 1, 2]), "kind": "directory"], forKey: "lanApkSync.source")

    let restored = preferences.load()
    XCTAssertEqual(restored["token"] as? String, String(repeating: "b", count: 24))
    XCTAssertNil(restored["sourcePath"])
    XCTAssertNotNil(restored["sourceError"])
  }

}
