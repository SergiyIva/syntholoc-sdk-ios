import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(CryptoKit)
  import CryptoKit
#else
  import COtaCrypto
#endif

public struct OtaConfiguration: Sendable {
  public let baseURL: URL
  public let distributionId, channel, catalogVersion, localeKey: String
  public let bundles: Set<String>
  public let fallbackLocaleKeys: [String]
  public let checkInterval: TimeInterval
  public let credential: (@Sendable () async throws -> String)?
  public init(
    baseURL: URL, distributionId: String, channel: String = "production", catalogVersion: String,
    localeKey: String, bundles: Set<String>, fallbackLocaleKeys: [String] = [],
    checkInterval: TimeInterval = 900,
    credential: (@Sendable () async throws -> String)? = nil
  ) {
    self.baseURL = baseURL
    self.distributionId = distributionId
    self.channel = channel
    self.catalogVersion = catalogVersion
    self.localeKey = localeKey
    self.bundles = bundles
    self.fallbackLocaleKeys = fallbackLocaleKeys
    self.checkInterval = checkInterval.isFinite ? max(60, min(86400, checkInterval)) : 900
    self.credential = credential
  }
}
/// Immutable scope. Checks stage data; the host chooses an activation boundary.
public actor OtaClient {
  private let config: OtaConfiguration
  private let cache: DiskCache
  private let origin: URL
  private let prefix: String
  private var catalogs: [String: Catalog] = [:]
  private var refresh: Task<OtaUpdate, Never>?
  private var refreshId: UUID?
  private var nextAttemptUptime: TimeInterval?
  private var nextCheckUptime: TimeInterval?
  private var observers: [UUID: AsyncStream<String?>.Continuation] = [:]
  public private(set) var activeReleaseId: String?
  public init(configuration: OtaConfiguration, cacheDirectory: URL) throws {
    let c = configuration
    let locales = [c.localeKey] + c.fallbackLocaleKeys
    guard let host = c.baseURL.host,
      c.baseURL.scheme == "https"
        || (c.baseURL.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)),
      c.baseURL.user == nil, c.baseURL.password == nil, c.baseURL.query == nil,
      c.baseURL.fragment == nil,
      Wire.name(c.distributionId), Wire.name(c.channel), Wire.name(c.catalogVersion),
      (1...50).contains(c.bundles.count), c.bundles.allSatisfy(Wire.name),
      (1...100).contains(locales.count), locales.allSatisfy(Wire.localeKey),
      Set(locales).count == locales.count,
      var parts = URLComponents(url: c.baseURL, resolvingAgainstBaseURL: false)
    else { throw OtaFailure.unsafeURL }
    parts.path = "/"
    parts.query = nil
    parts.fragment = nil
    guard let origin = parts.url else { throw OtaFailure.unsafeURL }
    self.config = c
    self.origin = origin
    self.prefix = "/ota/v1/distributions/\(c.distributionId)/channels/\(c.channel)/"
    let identity: [Any] = [
      origin.absoluteString, c.distributionId, c.channel, c.catalogVersion, c.localeKey,
      c.fallbackLocaleKeys, c.bundles.sorted(),
    ]
    self.cache = try DiskCache(
      directory: cacheDirectory.appendingPathComponent(
        Self.sha(try JSONSerialization.data(withJSONObject: identity)), isDirectory: true))
  }
  static func sha(_ data: Data) -> String {
    #if canImport(CryptoKit)
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #else
      var output = [UInt8](repeating: 0, count: 32)
      data.withUnsafeBytes { bytes in
        ota_sha256(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, &output)
      }
      return output.map { String(format: "%02x", $0) }.joined()
    #endif
  }
  static func verify(_ bytes: Data, hash: String, size: Int) throws {
    guard (0...10_000_000).contains(size), bytes.count == size, Wire.hash(hash), sha(bytes) == hash
    else { throw OtaFailure.integrity }
  }
  private func url(_ path: String, relativeTo base: URL? = nil) throws -> URL {
    guard !path.contains("%"), !path.contains("\\"), !path.contains("?"), !path.contains("#"),
      !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
      let result = URL(string: path, relativeTo: base ?? origin)?.absoluteURL,
      result.scheme == origin.scheme, result.host == origin.host, result.port == origin.port,
      result.user == nil, result.password == nil, result.path.hasPrefix(prefix)
    else { throw OtaFailure.unsafeURL }
    return result
  }
  private func request(_ url: URL, limit: Int, etag: String? = nil) async throws -> (Data?, String?)
  {
    var request = URLRequest(url: url)
    request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    request.setValue("SyntholocOTA/0.1 (Swift)", forHTTPHeaderField: "User-Agent")
    if let provider = config.credential {
      request.setValue("Bearer \(try await provider())", forHTTPHeaderField: "Authorization")
    }
    let (data, http) = try await BoundedHTTP.fetch(request, limit: limit)
    if http.statusCode == 304 { return (nil, http.value(forHTTPHeaderField: "ETag")) }
    guard http.statusCode == 200 else {
      let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      let wire = body?["code"] as? String ?? ""
      let code = Wire.matches(wire, "^OTA_[A-Z0-9_]{1,100}$") ? wire : "OTA_HTTP_\(http.statusCode)"
      let header = http.value(forHTTPHeaderField: "Retry-After") ?? ""
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
      let delay = TimeInterval(header) ?? formatter.date(from: header)?.timeIntervalSinceNow ?? 0
      throw OtaFailure.http(http.statusCode, code, min(86400, max(0, delay)))
    }
    return (data, http.value(forHTTPHeaderField: "ETag"))
  }
  private func parseSet(_ set: CachedSet) throws -> [String: Catalog] {
    let locales = [config.localeKey] + config.fallbackLocaleKeys
    try Wire.require(Wire.name(set.releaseId) && set.generation >= 0 && set.assets.count <= 5000)
    var parsed: [String: Catalog] = [:]
    var selections = Set<String>()
    for entry in set.assets {
      let asset = entry.asset
      try asset.validate()
      try Wire.require(
        locales.contains(entry.localeKey) && config.bundles.contains(asset.bundle)
          && Wire.language(entry.languageTag))
      try Wire.require(selections.insert("\(entry.localeKey)/\(asset.bundle)").inserted)
      let key = "\(entry.localeKey)/\(asset.namespace)"
      try Wire.require(parsed[key] == nil)
      parsed[key] = try Catalog.parse(
        format: asset.format, data: cache.blob(asset.sha256, bytes: asset.bytes),
        languageTag: entry.languageTag)
    }
    try Wire.require(
      locales.allSatisfy { locale in
        config.bundles.allSatisfy { selections.contains("\(locale)/\($0)") }
      })
    return parsed
  }
  @discardableResult public func loadCached() -> Bool {
    let state = cache.state()
    for set in [state.active, state.previous].compactMap({ $0 }) {
      if let parsed = try? parseSet(set) {
        catalogs = parsed
        activeReleaseId = set.releaseId
        try? cache.update { _ in }
        return true
      }
    }
    catalogs = [:]
    activeReleaseId = nil
    return false
  }
  public func checkForUpdates(forceRefresh: Bool = false) async -> OtaUpdate {
    if let refresh = refresh { return await refresh.value }
    let id = UUID()
    refreshId = id
    let task = Task { await self.check(force: forceRefresh) }
    refresh = task
    let result = await task.value
    if refreshId == id {
      refresh = nil
      refreshId = nil
    }
    return result
  }
  private func check(force: Bool) async -> OtaUpdate {
    guard let checkLock = try? cache.refreshLock() else { return .skipped }
    defer { withExtendedLifetime(checkLock) {} }
    let state = cache.state()
    let epoch = state.cacheEpoch
    let now = Date()
    if state.stopped == "retired" { return .retired }
    if state.stopped == "auth" { return .skipped }
    func pending(_ date: Date?, _ uptime: TimeInterval?, _ maximum: TimeInterval) -> Bool {
      if let uptime = uptime { return ProcessInfo.processInfo.systemUptime < uptime }
      guard let date = date else { return false }
      return date > now && date.timeIntervalSince(now) <= maximum
    }
    if pending(state.nextAttempt, nextAttemptUptime, state.retryDelay ?? 3600)
      || (!force && pending(state.nextCheck, nextCheckUptime, 86400))
    {
      return .skipped
    }
    do {
      try? cache.collect()
      try? cache.pruneScopes()
      let channelURL = try url(prefix + "manifest.json")
      var (data, etag) = try await request(channelURL, limit: 2_000_000, etag: state.etag)
      if data == nil && state.channel == nil {
        (data, etag) = try await request(channelURL, limit: 2_000_000)
      }
      let channel: ChannelManifest
      if let data = data {
        channel = try JSONDecoder().decode(ChannelManifest.self, from: data)
      } else if let cached = state.channel {
        channel = cached
      } else {
        throw OtaFailure.invalidManifest
      }
      try channel.validate()
      guard channel.distributionId == config.distributionId, channel.channel == config.channel,
        channel.catalogVersion == config.catalogVersion,
        channel.generation >= state.highestGeneration
      else { throw OtaFailure.incompatible }
      try cache.update { current in
        try Wire.require(
          current.cacheEpoch == epoch && channel.generation >= current.highestGeneration)
        current.channel = channel
        current.etag = etag ?? current.etag
        current.highestGeneration = channel.generation
      }
      if let active = cache.state().active, active.releaseId == channel.release.id,
        let parsed = try? parseSet(active)
      {
        try success(channel, epoch: epoch)
        catalogs = parsed
        activeReleaseId = active.releaseId
        return .unchanged
      }
      let manifestURL = try url(channel.release.manifestPath)
      guard let body = try await request(manifestURL, limit: 2_000_000).0 else {
        throw OtaFailure.invalidManifest
      }
      try Self.verify(body, hash: channel.release.sha256, size: channel.release.bytes)
      let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: body)
      try manifest.validate()
      guard manifest.distributionId == config.distributionId,
        manifest.releaseId == channel.release.id,
        manifest.catalogVersion == config.catalogVersion,
        Set(manifest.requiredBundles).isSubset(of: config.bundles)
      else { throw OtaFailure.incompatible }
      var assets: [CachedSet.Entry] = []
      for locale in [config.localeKey] + config.fallbackLocaleKeys {
        guard let mapping = manifest.locales.first(where: { $0.localeKey == locale }) else {
          throw OtaFailure.incompatible
        }
        for bundle in config.bundles.sorted() {
          guard let asset = mapping.assets.first(where: { $0.bundle == bundle }) else {
            throw OtaFailure.incompatible
          }
          if (try? cache.blob(asset.sha256, bytes: asset.bytes)) == nil {
            guard
              let data = try await request(
                url(asset.path, relativeTo: manifestURL), limit: 10_000_000
              ).0
            else { throw OtaFailure.integrity }
            try Self.verify(data, hash: asset.sha256, size: asset.bytes)
            _ = try Catalog.parse(
              format: asset.format, data: data, languageTag: mapping.languageTag)
            try cache.put(asset.sha256, data: data)
          }
          assets.append(.init(localeKey: locale, languageTag: mapping.languageTag, asset: asset))
        }
      }
      let candidate = CachedSet(
        releaseId: manifest.releaseId, generation: channel.generation, assets: assets)
      _ = try parseSet(candidate)
      try success(channel, epoch: epoch, candidate: candidate)
      return .available(manifest.releaseId)
    } catch {
      guard cache.state().cacheEpoch == epoch else { return .failed("OTA_CANCELLED") }
      var code = "OTA_INVALID_UPDATE"
      var retry: TimeInterval = 0
      var stopped: String?
      if let failure = error as? OtaFailure, case .http(let status, let wire, let delay) = failure {
        code = wire
        retry = delay
        if status == 410 && wire == "OTA_DISTRIBUTION_RETIRED" { stopped = "retired" }
        if status == 401 || status == 403 { stopped = "auth" }
        if status == 404 { retry = max(retry, 3600) }
      }
      let failures = min(1000, state.failures + 1)
      let delay = max(
        retry, min(3600, 15 * pow(2, Double(min(failures, 8))) * Double.random(in: 0.8...1.2)))
      try? cache.update { current in
        try Wire.require(current.cacheEpoch == epoch)
        current.failures = failures
        current.retryDelay = delay
        current.nextAttempt = Date().addingTimeInterval(delay)
        if let stopped = stopped { current.stopped = stopped }
      }
      nextAttemptUptime = ProcessInfo.processInfo.systemUptime + delay
      return stopped == "retired" ? .retired : .failed(code)
    }
  }
  private func success(_ channel: ChannelManifest, epoch: Int, candidate: CachedSet? = nil) throws {
    let delay =
      max(
        config.checkInterval, Double(min(86400, max(60, channel.recommendedCheckIntervalSeconds))))
      * Double.random(in: 0.9...1.1)
    try cache.update { state in
      try Wire.require(state.cacheEpoch == epoch && state.highestGeneration <= channel.generation)
      if let candidate = candidate { state.candidate = candidate }
      state.nextAttempt = nil
      state.retryDelay = nil
      state.failures = 0
      state.nextCheck = Date().addingTimeInterval(delay)
    }
    nextAttemptUptime = nil
    nextCheckUptime = ProcessInfo.processInfo.systemUptime + delay
  }
  public func activate(_ releaseId: String) throws {
    let current = cache.state()
    guard let candidate = current.candidate, candidate.releaseId == releaseId,
      candidate.generation >= current.highestGeneration
    else { throw OtaFailure.noCandidate }
    let parsed = try parseSet(candidate)
    try cache.update { state in
      try Wire.require(
        state.cacheEpoch == current.cacheEpoch && state.candidate?.releaseId == releaseId
          && candidate.generation >= state.highestGeneration)
      state.previous = state.active
      state.active = candidate
      state.candidate = nil
    }
    catalogs = parsed
    activeReleaseId = releaseId
    try? cache.collect()
    for observer in observers.values { observer.yield(releaseId) }
  }
  public func string(namespace: String, key: String, fallback: String) -> String {
    for locale in [config.localeKey] + config.fallbackLocaleKeys {
      if let value = catalogs["\(locale)/\(namespace)"]?.strings[key] { return value }
    }
    return fallback
  }
  public func snapshot() -> OtaLocalizationSnapshot {
    OtaLocalizationSnapshot(
      releaseId: activeReleaseId, catalogs: catalogs,
      locales: [config.localeKey] + config.fallbackLocaleKeys)
  }
  public func formatted(
    namespace: String, key: String, arguments: [OtaArgument], device: OtaDevice = .other,
    fallback: String
  ) -> String {
    snapshot().formatted(
      namespace: namespace, key: key, arguments: arguments, device: device, fallback: fallback)
  }
  public func plural(
    namespace: String, key: String, variable: String, category: String, fallback: String
  ) -> String {
    for locale in [config.localeKey] + config.fallbackLocaleKeys {
      if let forms = catalogs["\(locale)/\(namespace)"]?.plurals[key]?[variable],
        let value = forms[category] ?? forms["other"]
      {
        return value
      }
    }
    return fallback
  }
  public func resetFailureState() throws {
    refresh?.cancel()
    refresh = nil
    refreshId = nil
    nextAttemptUptime = nil
    nextCheckUptime = nil
    try cache.update {
      $0.cacheEpoch += 1
      $0.stopped = nil
      $0.nextAttempt = nil
      $0.nextCheck = nil
      $0.retryDelay = nil
      $0.failures = 0
    }
  }
  public func clearCache() throws {
    refresh?.cancel()
    refresh = nil
    refreshId = nil
    nextAttemptUptime = nil
    nextCheckUptime = nil
    try cache.update { state in
      var empty = CacheState()
      empty.revision = state.revision
      empty.cacheEpoch = state.cacheEpoch + 1
      state = empty
    }
    catalogs = [:]
    activeReleaseId = nil
    for observer in observers.values { observer.yield(nil) }
  }
  public func activations() -> AsyncStream<String?> {
    let id = UUID()
    return AsyncStream { continuation in
      observers[id] = continuation
      continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
    }
  }
  private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}
