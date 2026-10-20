# Syntholoc mobile SDK API

## Android

Install the public Maven artifacts `com.syntholoc:ota:0.1.0` and optional
`com.syntholoc:ota-compose:0.1.0` from
`https://raw.githubusercontent.com/SergiyIva/syntholoc-sdk-android/maven`.
No credentials or private repository access are needed. See the
[mobile quickstart](INTEGRATION_RU.md) for Gradle configuration.
Requirements: Android API 24+, JDK 17, Kotlin 2.2+.
Public source: https://github.com/SergiyIva/syntholoc-sdk-android .

```kotlin
val ota = OtaClient(
    OtaConfig(
        baseUrl = "https://api.syntholoc.com",
        distributionId = "dst_your_public_id", catalogVersion = "app-v1",
        localeKey = "ru", bundles = setOf("app")
    ), File(context.filesDir, "ota")
)
ota.loadCached() // app-private files, no network
// Run blocking I/O on an application-owned background executor / Dispatchers.IO.
val update = ota.checkForUpdates()
if (update.status == "available") ota.activate(update.releaseId!!)
val title = ota.string("app", "screen.title") { bundledTitle }
```

Call `close()` when disposing the client to cancel its connection/executor. Use a separate
client for another immutable locale/channel scope. A network check has its own nonblocking
process lock; startup reads and cache clearing do not wait on network I/O. Epoch fencing
prevents an older check from restoring a cleared candidate. Reads are bounded, hashes are
rechecked, active/previous/candidate blobs survive GC, and unreferenced blobs have a 24-hour
grace. Dormant scopes beyond eight retain generation/epoch tombstones.

`OtaResources` offers getText/getString/getQuantityString/getStringArray using compiled
resource names, ICU cardinal rules and an optional resource-package filter. Failed Java
formatting uses the bundled formatted string. Android XML supports string/plural/array
resources; getText preserves supported inline b/i/u/tt/big/small/sup/sub/strike/font/a/br spans.
Unknown markup and DTDs reject the entire candidate. Plural/array lookups currently return
plain text. Existing resource IDs, theme attributes and styles remain compiled in the host.

For an Activity/Fragment, wrap its context using `provider.wrap(context)`. Compiled XML
attributes can bypass Resources overrides through TypedArray, so the host's existing
`LayoutInflater.Factory2` must also call `provider.localize(view, attrs)` after creating
**each** View. This handles TextView text/hint and View contentDescription, including custom
TextView subclasses. Keep the existing AppCompat/Fragment factory as the creator. Recreate
or explicitly rebind existing Views at the host's chosen activation boundary.

The optional `com.syntholoc:ota-compose` artifact keeps Compose out of the core AAR:

```kotlin
@Composable
fun Title(ota: OtaClient) {
    val strings = rememberOtaResources(ota, namespace = "app")
    Text(strings.getString(R.string.screen_title))
}
```

`rememberOtaSnapshot` and `rememberOtaResources` observe **activation**, post updates to the
main thread and unsubscribe on disposal. A staged download does not recompose the screen.
Each composition uses one immutable snapshot. JSON keys with literal dots use
`snapshot.string(namespace, key) { bundled }`; they do not require Android resource names.
JVM loopback tests cover wire validation, corruption, 304, auth stop, rollback and clear races.
Device tests exercise styled Resources, XML inflation and actual Compose activation/clear.

## Apple

Add `https://github.com/SergiyIva/syntholoc-sdk-ios.git` in Xcode / SwiftPM,
version `0.1.0`, products `SyntholocOTA` and optionally `SyntholocOTASwiftUI`.
The repository is public; no GitHub login is required. Minimum iOS 15 / macOS 12,
Swift tools 5.9. The actor owns network refresh state and app-private atomic cache files.
Use the explicit provider; no Bundle method replacement is performed. Core tests and
release builds run with the pinned Linux Swift toolchain. Apple/SwiftUI compilation
and iOS device UI tests still require macOS.

```swift
let ota = try OtaClient(configuration: OtaConfiguration(
    baseURL: URL(string: "https://api.syntholoc.com")!,
    distributionId: "dst_your_public_id", catalogVersion: "app-v1",
    localeKey: "ru", bundles: ["app"]
), cacheDirectory: applicationSupportURL.appendingPathComponent("ota"))
await ota.loadCached()
if case let .available(id) = await ota.checkForUpdates() {
    try await ota.activate(id)
}
let title = await ota.string(namespace: "app", key: "screen.title", fallback: bundledTitle)
```

The Apple parser handles JSON, `.strings`, stringsdict named plural variables and the
xcstrings string/plural/device/substitution profile. Cardinal selection uses vendored Unicode
CLDR 47 with visible decimal operands; `.decimal("1.00")` preserves precision for plural rules.
Downloaded printf expressions are formatted one typed conversion at a time; pointer, `%n`,
`%s`, dynamic width and mismatched argument types fall back to the already formatted bundled
value. Use `.integer(Int64)`, `.number(Double)`, `.decimal(String)` or `.string(String)` arguments:

```swift
let snapshot = await ota.snapshot()
let message = snapshot.formatted(namespace: "app", key: "items",
    arguments: [.integer(3)], device: .iphone, fallback: bundledFormattedMessage)
let provider = snapshot.provider(bundle: .main, tables: ["Localizable": "app"])
let title = provider.localizedString(forKey: "screen.title")
```

Explicit table mapping prevents unrelated Bundle lookups from using an OTA namespace.
Pass the actual device class when using device variations. Keep one immutable snapshot for
an entire UI frame. Unsupported variants or malformed formatting use bundled fallback.
The separate `SyntholocOTASwiftUI` product provides a main-actor `OtaLocalization` observable
object and `OtaText` (verbatim text, with optional typed arguments). Inject it with
`.environmentObject(localization)` and call `activate` at an application-controlled boundary.
It observes activation events, loads cached content and cancels its subscription on disposal.

The core uses bounded URLSession delegates, HTTP(S) scope checks, SHA-256 verification,
short metadata locks separate from the network lock, atomic pointer writes, persisted
backoff/auth stop, epoch fencing, 24-hour blob grace and eight-scope retention. Startup
does not wait for a network lock. Linux uses system OpenSSL only for the testable core;
Apple builds use CryptoKit. Run `bash scripts/check.sh` for real loopback
HTTP tests, shared fixtures, formatting tests and a release build.

