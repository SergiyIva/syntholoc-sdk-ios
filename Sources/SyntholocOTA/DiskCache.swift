import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Kernel locks are released on process death; a network check never holds the metadata lock.
final class CacheLock: @unchecked Sendable {
  private let descriptor: Int32
  init(_ file: URL, nonblocking: Bool = false) throws {
    descriptor = open(file.path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw OtaFailure.integrity }
    guard flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
      close(descriptor)
      throw OtaFailure.incompatible
    }
  }
  deinit {
    _ = flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
final class DiskCache: @unchecked Sendable {
  let directory: URL
  init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }
  private func rawState() -> CacheState {
    guard
      let data = try? bounded(
        directory.appendingPathComponent("state.json"), maximum: 16 * 1024 * 1024),
      let state = try? JSONDecoder().decode(CacheState.self, from: data), state.revision >= 0
    else { return CacheState() }
    return state
  }
  func state() -> CacheState { rawState() }
  @discardableResult func update<T>(_ change: (inout CacheState) throws -> T) throws -> T {
    let lock = try CacheLock(directory.appendingPathComponent("metadata.lock"))
    defer { withExtendedLifetime(lock) {} }
    var state = rawState()
    let result = try change(&state)
    state.revision += 1
    state.lastUsedAt = Date()
    try JSONEncoder().encode(state).write(
      to: directory.appendingPathComponent("state.json"), options: .atomic)
    return result
  }
  func refreshLock() throws -> CacheLock {
    try CacheLock(directory.appendingPathComponent("refresh.lock"), nonblocking: true)
  }
  func blob(_ hash: String, bytes: Int) throws -> Data {
    guard Wire.hash(hash), (0...10_000_000).contains(bytes) else { throw OtaFailure.integrity }
    let file = directory.appendingPathComponent(hash)
    let data = try bounded(file, maximum: 10_000_000)
    try OtaClient.verify(data, hash: hash, size: bytes)
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    return data
  }
  func put(_ hash: String, data: Data) throws {
    guard Wire.hash(hash), data.count <= 10_000_000, OtaClient.sha(data) == hash else {
      throw OtaFailure.integrity
    }
    try data.write(to: directory.appendingPathComponent(hash), options: .atomic)
  }
  private func bounded(_ url: URL, maximum: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    guard try handle.seekToEnd() <= UInt64(maximum) else { throw OtaFailure.integrity }
    try handle.seek(toOffset: 0)
    let data = try handle.read(upToCount: maximum + 1) ?? Data()
    guard data.count <= maximum else { throw OtaFailure.integrity }
    return data
  }
  func collect() throws {
    let lock = try CacheLock(directory.appendingPathComponent("metadata.lock"))
    defer { withExtendedLifetime(lock) {} }
    let state = rawState()
    let references = Set(
      [state.active, state.previous, state.candidate].compactMap { $0 }.flatMap {
        $0.assets.map { $0.asset.sha256 }
      })
    let cutoff = Date().addingTimeInterval(-86400)
    for file in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
    {
      guard Wire.hash(file.lastPathComponent), !references.contains(file.lastPathComponent) else {
        continue
      }
      if let modified = try file.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate, modified < cutoff
      {
        try FileManager.default.removeItem(at: file)
      }
    }
  }
  /// Evict dormant locale/channel scopes while retaining an epoch/generation tombstone.
  func pruneScopes(maximum: Int = 8) throws {
    let root = directory.deletingLastPathComponent()
    let siblings = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    )
    .filter { Wire.hash($0.lastPathComponent) && $0 != directory }
    .compactMap { url -> (URL, Date)? in
      guard
        let data = try? bounded(
          url.appendingPathComponent("state.json"), maximum: 16 * 1024 * 1024),
        let state = try? JSONDecoder().decode(CacheState.self, from: data)
      else { return nil }
      return (url, state.lastUsedAt ?? .distantPast)
    }.sorted { $0.1 > $1.1 }
    for (url, _) in siblings.dropFirst(max(0, maximum - 1)) {
      let old = try DiskCache(directory: url)
      guard let network = try? old.refreshLock() else { continue }
      defer { withExtendedLifetime(network) {} }
      let lock = try CacheLock(url.appendingPathComponent("metadata.lock"))
      let current = old.rawState()
      if current.active != nil || current.previous != nil || current.candidate != nil
        || current.channel != nil
      {
        var empty = CacheState()
        empty.revision = current.revision + 1
        empty.cacheEpoch = current.cacheEpoch + 1
        empty.highestGeneration = current.highestGeneration
        empty.lastUsedAt = current.lastUsedAt
        try JSONEncoder().encode(empty).write(
          to: url.appendingPathComponent("state.json"), options: .atomic)
      }
      withExtendedLifetime(lock) {}
      // A separate scope collection on a later pass observes the 24-hour blob grace.
    }
    for (url, _) in siblings { try? DiskCache(directory: url).collect() }
  }
}
