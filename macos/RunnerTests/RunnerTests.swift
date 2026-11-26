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

  func testMultipleSourcesAreAppendedDeduplicatedAndRestored() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("lan-apk-multi-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = directory.appendingPathComponent("a.apk")
    let b = directory.appendingPathComponent("b.apk")
    try Data([1]).write(to: a)
    try Data([2]).write(to: b)
    let store = SharingPreferences(defaults: defaults)
    try store.rememberSource(a, kind: "file")
    try store.rememberSources([a, b], kind: "file")
    try store.rememberSource(directory, kind: "directory")
    let sources = try XCTUnwrap(SharingPreferences(defaults: defaults).load()["sources"] as? [[String: String]])
    XCTAssertEqual(sources.count, 3)
    XCTAssertEqual(Set(sources.compactMap { $0["kind"] }), Set(["file", "directory"]))
  }

  func testLegacyBookmarkMigratesWithoutChangingTheLink() throws {
    let store = SharingPreferences(defaults: defaults)
    let directory = FileManager.default.temporaryDirectory
    try store.rememberSource(directory, kind: "directory")
    let records = try XCTUnwrap(defaults.array(forKey: "lanApkSync.sources") as? [[String: Any]])
    defaults.set(records[0], forKey: "lanApkSync.source")
    defaults.removeObject(forKey: "lanApkSync.sources")
    store.save(["token": String(repeating: "c", count: 24)])
    let restored = SharingPreferences(defaults: defaults).load()
    XCTAssertEqual(restored["token"] as? String, String(repeating: "c", count: 24))
    XCTAssertEqual((restored["sources"] as? [[String: String]])?.count, 1)
    XCTAssertNil(defaults.object(forKey: "lanApkSync.source"))
  }

  func testRemovalPersistsExclusionButNeverDeletesTheApk() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("lan-remove-\(UUID().uuidString).apk")
    try Data([1]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let store = SharingPreferences(defaults: defaults)
    try store.rememberSource(file, kind: "file")
    store.removeSource(path: file.path, excludeApk: true)
    let restored = SharingPreferences(defaults: defaults).load()
    XCTAssertEqual((restored["sources"] as? [[String: String]])?.count, 0)
    XCTAssertTrue((restored["excludedPaths"] as? [String])?.contains(file.path) == true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    try store.rememberSource(file, kind: "file")
    XCTAssertEqual((store.load()["excludedPaths"] as? [String])?.count, 0)
  }

  func testOneBrokenBookmarkDoesNotWithdrawOtherSources() throws {
    let store = SharingPreferences(defaults: defaults)
    try store.rememberSource(FileManager.default.temporaryDirectory, kind: "directory")
    var records = try XCTUnwrap(defaults.array(forKey: "lanApkSync.sources") as? [[String: Any]])
    records.append(["bookmark": Data([0, 1, 2]), "kind": "file"])
    defaults.set(records, forKey: "lanApkSync.sources")
    let restored = store.load()
    XCTAssertEqual((restored["sources"] as? [[String: String]])?.count, 1)
    XCTAssertNotNil(restored["sourceError"])
  }

}
