// swift-tools-version: 5.9
import PackageDescription

var targets: [Target] = []
var coreDependencies: [Target.Dependency] = []
#if os(Linux)
  targets.append(.target(name: "COtaCrypto", linkerSettings: [.linkedLibrary("crypto")]))
  coreDependencies.append("COtaCrypto")
#endif
targets.append(
  .target(name: "SyntholocOTA", dependencies: coreDependencies, resources: [.process("Resources")]))
targets.append(.target(name: "SyntholocOTASwiftUI", dependencies: ["SyntholocOTA"]))
targets.append(
  .testTarget(
    name: "SyntholocOTATests", dependencies: ["SyntholocOTA"], resources: [.copy("Fixtures")]))
let package = Package(
  name: "SyntholocOTA", platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    .library(name: "SyntholocOTA", targets: ["SyntholocOTA"]),
    .library(name: "SyntholocOTASwiftUI", targets: ["SyntholocOTASwiftUI"]),
  ], targets: targets
)
