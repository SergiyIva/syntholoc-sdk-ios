import Foundation

/// Synchronous, immutable view of one verified active set. Safe to keep for an entire rendered frame.
public struct OtaLocalizationSnapshot: Sendable {
  public let releaseId: String?
  let catalogs: [String: Catalog]
  let locales: [String]
  public static let bundled = OtaLocalizationSnapshot(releaseId: nil, catalogs: [:], locales: [])
  public func string(namespace: String, key: String, device: OtaDevice = .other, fallback: String)
    -> String
  {
    for locale in locales {
      if let catalog = catalogs["\(locale)/\(namespace)"],
        let value = catalog.entries[key]?.raw(device: device) ?? catalog.strings[key]
      {
        return value
      }
    }
    return fallback
  }
  public func formatted(
    namespace: String, key: String, arguments: [OtaArgument], device: OtaDevice = .other,
    fallback: String
  ) -> String {
    for locale in locales {
      guard let catalog = catalogs["\(locale)/\(namespace)"], let node = catalog.entries[key] else {
        continue
      }
      if let value = try? node.render(
        arguments: arguments, languageTag: catalog.languageTag, device: device
      ).0 {
        return value
      }
    }
    return fallback
  }
  public func provider(bundle: Bundle = .main, tables: [String: String]) -> OtaBundleProvider {
    OtaBundleProvider(snapshot: self, bundle: bundle, tables: tables)
  }
}

/// Explicit Bundle/NSLocalizedString adapter. Tables map to namespaces; no global method replacement.
public struct OtaBundleProvider {
  private let snapshot: OtaLocalizationSnapshot
  private let bundle: Bundle
  private let tables: [String: String]
  init(snapshot: OtaLocalizationSnapshot, bundle: Bundle, tables: [String: String]) {
    self.snapshot = snapshot
    self.bundle = bundle
    self.tables = tables
  }
  public func localizedString(forKey key: String, value: String? = nil, table: String? = nil)
    -> String
  {
    let fallback = bundle.localizedString(forKey: key, value: value, table: table)
    guard let namespace = tables[table ?? "Localizable"] else { return fallback }
    return snapshot.string(namespace: namespace, key: key, fallback: fallback)
  }
  public func formatted(
    forKey key: String, table: String? = nil, arguments: [OtaArgument], device: OtaDevice = .other,
    bundledFallback: String
  ) -> String {
    guard let namespace = tables[table ?? "Localizable"] else { return bundledFallback }
    return snapshot.formatted(
      namespace: namespace, key: key, arguments: arguments, device: device,
      fallback: bundledFallback)
  }
}
