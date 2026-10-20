import XCTest

@testable import SyntholocOTA

final class ClientTests: XCTestCase {
  private var directory: URL!
  private var control: URL!
  private var baseURL: URL!
  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["OTA_TEST_CONTROL"], let origin = environment["OTA_TEST_ORIGIN"]
    else {
      throw XCTSkip("Run .github/scripts/ota-swift-check.sh to start the loopback origin")
    }
    control = URL(fileURLWithPath: path)
    baseURL = URL(string: origin)!
    try? FileManager.default.removeItem(
      at: control.deletingPathExtension().appendingPathExtension("requests"))
    try configure([:])
  }
  override func tearDownWithError() throws {
    if let directory = directory { try? FileManager.default.removeItem(at: directory) }
  }
  private func configure(_ value: [String: Any]) throws {
    try JSONSerialization.data(withJSONObject: value).write(to: control, options: .atomic)
  }
  private func client() throws -> OtaClient {
    try OtaClient(
      configuration: .init(
        baseURL: baseURL, distributionId: "dist", catalogVersion: "v1", localeKey: "en",
        bundles: ["app"]), cacheDirectory: directory.appendingPathComponent("cache"))
  }
  private func waitForRequest() async throws {
    for _ in 0..<200 {
      if FileManager.default.fileExists(
        atPath: control.deletingPathExtension().appendingPathExtension("requests").path)
      {
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("loopback origin did not receive a request")
  }
  func testStageActivateOfflineRestart304AndGenerationRollback() async throws {
    let first = try client()
    let staged = await first.checkForUpdates()
    XCTAssertEqual(staged, .available("release1"))
    let before = await first.snapshot()
    XCTAssertEqual(before.string(namespace: "app", key: "hello", fallback: "Bundled"), "Bundled")
    try await first.activate("release1")
    let restart = try client()
    let loaded = await restart.loadCached()
    XCTAssertTrue(loaded)
    let active = await restart.snapshot()
    XCTAssertEqual(active.string(namespace: "app", key: "hello", fallback: "Bundled"), "Hello 1")
    let unchanged = await restart.checkForUpdates(forceRefresh: true)
    XCTAssertEqual(unchanged, .unchanged)
    try configure(["version": 2, "strings": ["new": "New"]])
    try await restart.resetFailureState()
    let update = await restart.checkForUpdates(forceRefresh: true)
    XCTAssertEqual(update, .available("release2"))
    try await restart.activate("release2")
    let replaced = await restart.snapshot()
    XCTAssertEqual(replaced.string(namespace: "app", key: "hello", fallback: "Bundled"), "Bundled")
    try configure(["version": 1, "generation": 3])
    try await restart.resetFailureState()
    let rollback = await restart.checkForUpdates(forceRefresh: true)
    XCTAssertEqual(rollback, .available("release1"))
    try await restart.activate("release1")
    try configure(["status": 503])
    let offline = try client()
    let offlineLoaded = await offline.loadCached()
    XCTAssertTrue(offlineLoaded)
    let restored = await offline.snapshot()
    XCTAssertEqual(restored.string(namespace: "app", key: "hello", fallback: "Bundled"), "Hello 1")
  }
  func testIntegrityFailureBackoffAndAuthStop() async throws {
    let client = try client()
    _ = await client.checkForUpdates()
    try await client.activate("release1")
    try configure(["version": 2, "badHash": true])
    try await client.resetFailureState()
    let bad = await client.checkForUpdates(forceRefresh: true)
    XCTAssertEqual(bad, .failed("OTA_INVALID_UPDATE"))
    let retry = await client.checkForUpdates(forceRefresh: true)
    XCTAssertEqual(retry, .skipped)
    let snapshot = await client.snapshot()
    XCTAssertEqual(snapshot.releaseId, "release1")
    try configure(["status": 401])
    try await client.resetFailureState()
    let denied = await client.checkForUpdates(forceRefresh: true)
    XCTAssertEqual(denied, .failed("OTA_KEY_INVALID"))
    try configure(["version": 2])
    let stopped = await client.checkForUpdates(forceRefresh: true)
    XCTAssertEqual(stopped, .skipped)
    try await client.resetFailureState()
    let recovered = await client.checkForUpdates(forceRefresh: true)
    XCTAssertEqual(recovered, .available("release2"))
  }
  func testClearFencesInFlightCheckAndStartupDoesNotWaitForNetwork() async throws {
    try configure(["delay": 0.5])
    let first = try client()
    let second = try client()
    let pending = Task { await first.checkForUpdates() }
    try await waitForRequest()
    let start = Date()
    let loaded = await second.loadCached()
    XCTAssertFalse(loaded)
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    let concurrent = await second.checkForUpdates()
    XCTAssertEqual(concurrent, .skipped)
    try await second.clearCache()
    let result = await pending.value
    XCTAssertEqual(result, .failed("OTA_CANCELLED"))
    let restarted = try client()
    let stillEmpty = await restarted.loadCached()
    XCTAssertFalse(stillEmpty)
    try configure([:])
    let fresh = await restarted.checkForUpdates(forceRefresh: true)
    XCTAssertEqual(fresh, .available("release1"))
  }
}
