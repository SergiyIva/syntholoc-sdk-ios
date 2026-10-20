import XCTest

@testable import SyntholocOTA

final class CacheTests: XCTestCase {
  func testBlobGraceAndScopeEvictionPreserveGenerationTombstones() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try DiskCache(
      directory: root.appendingPathComponent(String(repeating: "a", count: 64)))
    let current = try DiskCache(
      directory: root.appendingPathComponent(String(repeating: "b", count: 64)))
    let bytes = Data("{\"hello\":\"Hello\"}".utf8)
    let hash = OtaClient.sha(bytes)
    let asset = Asset(
      id: "asset", bundle: "app", namespace: "app", format: "JSON_FLAT",
      path: "assets/asset/\(hash)", sha256: hash, contentType: "application/json",
      bytes: bytes.count)
    try old.put(hash, data: bytes)
    let stale = Date().addingTimeInterval(-172800)
    try old.update { state in
      state.highestGeneration = 5
      state.active = CachedSet(
        releaseId: "r1", generation: 5,
        assets: [.init(localeKey: "en", languageTag: "en", asset: asset)])
    }
    try FileManager.default.setAttributes(
      [.modificationDate: stale], ofItemAtPath: old.directory.appendingPathComponent(hash).path)
    let orphan = Data("orphan".utf8)
    let orphanHash = OtaClient.sha(orphan)
    try old.put(orphanHash, data: orphan)
    try FileManager.default.setAttributes(
      [.modificationDate: stale],
      ofItemAtPath: old.directory.appendingPathComponent(orphanHash).path)
    let recent = Data("recent".utf8)
    let recentHash = OtaClient.sha(recent)
    try old.put(recentHash, data: recent)
    try old.collect()
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: old.directory.appendingPathComponent(hash).path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: old.directory.appendingPathComponent(orphanHash).path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: old.directory.appendingPathComponent(recentHash).path))
    try current.pruneScopes(maximum: 1)
    let evicted = old.state()
    XCTAssertNil(evicted.active)
    XCTAssertEqual(evicted.highestGeneration, 5)
    XCTAssertEqual(evicted.cacheEpoch, 1)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: old.directory.appendingPathComponent(hash).path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: old.directory.appendingPathComponent(recentHash).path))
  }
}
