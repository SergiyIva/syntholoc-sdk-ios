# Syntholoc OTA iOS SDK

Public Swift Package for OTA translations. No access to the private Syntholoc
project, GitHub login, or registry token is required. MIT license.
Minimum iOS 15 / macOS 12, Swift tools 5.9.

In Xcode, **Add Package Dependencies** using:

```text
https://github.com/SergiyIva/syntholoc-sdk-ios.git
```

Select **Exact Version: 0.1.1** and add product `SyntholocOTA`.
For SwiftUI, also add `SyntholocOTASwiftUI`.

```swift
.package(url: "https://github.com/SergiyIva/syntholoc-sdk-ios.git", exact: "0.1.1")
// In your target dependencies:
.product(name: "SyntholocOTA", package: "syntholoc-sdk-ios")
```

Commit your app's `Package.resolved` to pin the same version on CI.
[Mobile integration guide (Russian)](INTEGRATION_RU.md) covers Bundle providers,
SwiftUI, cache, authentication, activation and QA.
[API reference and limitations](API.md#apple).

Features include actor-based delivery, integrity checks, atomic cache activation,
explicit Bundle table mapping, immutable snapshots, typed Apple formatting and CLDR
plural rules. Original bundled translations remain the offline fallback. Publication
of an SDK is separate from publication of translations in a Syntholoc distribution.

`bash scripts/check.sh` builds and runs network/cache/formatting XCTest cases against
a disposable loopback origin and builds release mode. Requires Python 3; Linux also
requires OpenSSL development headers. Apple uses CryptoKit. CLDR data and its Unicode
license are included in the package.

Linux core tests and release builds have passed. Apple/SwiftUI compilation and device
UI acceptance remain to be checked on a Mac before production integration.
