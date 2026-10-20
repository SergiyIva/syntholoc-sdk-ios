import Foundation

public enum OtaFailure: Error {
  case invalidManifest, integrity, incompatible, unsafeURL, noCandidate
  case http(Int, String, TimeInterval)
}
public enum OtaUpdate: Sendable, Equatable {
  case available(String)
  case unchanged, skipped, retired
  case failed(String)
}
struct Asset: Codable, Sendable {
  let id, bundle, namespace, format, path, sha256, contentType: String
  let bytes: Int
}
struct ReleaseManifest: Codable, Sendable {
  struct Locale: Codable, Sendable {
    let localeKey, languageTag: String
    let assets: [Asset]
  }
  let protocolVersion: Int
  let distributionId, releaseId, catalogVersion, createdAt, sourceDigest: String
  let requiredBundles: [String]
  let locales: [Locale]
  func validate() throws {
    try Wire.require(protocolVersion == 1 && Wire.name(distributionId) && Wire.name(releaseId))
    try Wire.require(Wire.text(catalogVersion) && Wire.hash(sourceDigest) && Wire.date(createdAt))
    try Wire.require(
      requiredBundles.count <= 50 && Set(requiredBundles).count == requiredBundles.count
        && requiredBundles.allSatisfy(Wire.name))
    try Wire.require(
      (1...100).contains(locales.count) && Set(locales.map(\.localeKey)).count == locales.count)
    var ids = Set<String>()
    var total = 0
    for locale in locales {
      try Wire.require(
        Wire.text(locale.localeKey) && Wire.language(locale.languageTag)
          && locale.assets.count <= 50)
      try Wire.require(Set(locale.assets.map(\.bundle)).count == locale.assets.count)
      try Wire.require(Set(requiredBundles).isSubset(of: Set(locale.assets.map(\.bundle))))
      for asset in locale.assets {
        try asset.validate()
        try Wire.require(ids.insert(asset.id).inserted)
        total += asset.bytes
        try Wire.require(total <= 100 * 1024 * 1024)
      }
    }
  }
}
struct ChannelManifest: Codable, Sendable {
  struct Release: Codable, Sendable {
    let id, manifestPath, sha256: String
    let bytes: Int
  }
  let protocolVersion: Int
  let distributionId, channel, catalogVersion: String
  let generation: Int
  let release: Release
  let recommendedCheckIntervalSeconds: Int
  func validate() throws {
    try Wire.require(
      protocolVersion == 1 && Wire.name(distributionId) && Wire.name(channel)
        && Wire.text(catalogVersion))
    try Wire.require(
      (0...9_007_199_254_740_991).contains(generation)
        && (0...86400).contains(recommendedCheckIntervalSeconds))
    try Wire.require(
      Wire.name(release.id) && Wire.hash(release.sha256) && (0...2_000_000).contains(release.bytes))
    try Wire.require(
      release.manifestPath
        == "/ota/v1/distributions/\(distributionId)/channels/\(channel)/releases/\(release.id)/manifest.json"
    )
  }
}
extension Asset {
  func validate() throws {
    let types = [
      "JSON_FLAT": "application/json", "JSON_NESTED": "application/json",
      "ANDROID_XML": "application/xml",
      "IOS_STRINGS": "text/plain", "IOS_STRINGSDICT": "application/xml",
      "IOS_XCSTRINGS": "application/json",
    ]
    try Wire.require(
      Wire.name(id) && Wire.name(bundle) && Wire.name(namespace) && Wire.hash(sha256))
    try Wire.require(
      (0...10_000_000).contains(bytes) && types[format] == contentType
        && path == "assets/\(id)/\(sha256)")
  }
}
enum Wire {
  static func require(_ condition: Bool) throws {
    if !condition { throw OtaFailure.invalidManifest }
  }
  static func matches(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
  }
  static func name(_ s: String) -> Bool { matches(s, "^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$") }
  static func text(_ s: String) -> Bool { !s.isEmpty && s.utf8.count <= 2048 && s.count <= 512 }
  static func hash(_ s: String) -> Bool { matches(s, "^[a-f0-9]{64}$") }
  static func language(_ s: String) -> Bool {
    text(s) && matches(s, "^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$")
  }
  static func localeKey(_ s: String) -> Bool { matches(s, "^[A-Za-z0-9][A-Za-z0-9@._-]{0,79}$") }
  static func date(_ s: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if formatter.date(from: s) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: s) != nil
  }
}
struct CachedSet: Codable, Sendable {
  struct Entry: Codable, Sendable {
    let localeKey, languageTag: String
    let asset: Asset
  }
  let releaseId: String
  let generation: Int
  let assets: [Entry]
}
struct CacheState: Codable {
  var revision = 0
  var cacheEpoch = 0
  var active, previous, candidate: CachedSet?
  var channel: ChannelManifest?
  var etag: String?
  var highestGeneration = 0
  var lastUsedAt: Date?
  var nextAttempt, nextCheck: Date?
  var retryDelay: TimeInterval?
  var stopped: String?
  var failures = 0
}
