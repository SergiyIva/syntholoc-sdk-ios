#if canImport(SwiftUI)
  import SwiftUI
  import SyntholocOTA

  @MainActor public final class OtaLocalization: ObservableObject {
    @Published public private(set) var snapshot = OtaLocalizationSnapshot.bundled
    private let client: OtaClient
    private var observer: Task<Void, Never>?
    public init(client: OtaClient) {
      self.client = client
      observer = Task { [weak self, client] in
        let events = await client.activations()
        await client.loadCached()
        let initial = await client.snapshot()
        self?.snapshot = initial
        for await _ in events {
          guard !Task.isCancelled, self != nil else { break }
          let current = await client.snapshot()
          self?.snapshot = current
        }
      }
    }
    deinit { observer?.cancel() }
    public func stageUpdates(forceRefresh: Bool = false) async -> OtaUpdate {
      await client.checkForUpdates(forceRefresh: forceRefresh)
    }
    public func activate(_ releaseId: String) async throws {
      try await client.activate(releaseId)
      snapshot = await client.snapshot()
    }
    public func clearCache() async throws {
      try await client.clearCache()
      snapshot = await client.snapshot()
    }
  }

  /// Use .environmentObject(localization). Downloaded strings are always displayed verbatim.
  public struct OtaText: View {
    @EnvironmentObject private var localization: OtaLocalization
    private let namespace, key, fallback: String
    private let arguments: [OtaArgument]
    private let device: OtaDevice
    public init(
      _ key: String, namespace: String, fallback: String, arguments: [OtaArgument] = [],
      device: OtaDevice = .other
    ) {
      self.key = key
      self.namespace = namespace
      self.fallback = fallback
      self.arguments = arguments
      self.device = device
    }
    public var body: some View {
      Text(
        verbatim: arguments.isEmpty
          ? localization.snapshot.string(
            namespace: namespace, key: key, device: device, fallback: fallback)
          : localization.snapshot.formatted(
            namespace: namespace, key: key, arguments: arguments, device: device, fallback: fallback
          ))
    }
  }
#endif
