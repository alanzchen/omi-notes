// swift-tools-version: 6.0
// The Watch app's real WatchSync.swift on the host, with SDK doubles (WatchConnectivity, WatchKit), a deterministic clock
// and in-memory preferences: `./run.sh`. Its checks come from Astra's review (nightly-2026-11-15 IT1).
import PackageDescription
let package = Package(name: "WatchSyncHarness", platforms: [.macOS(.v14)],
                      dependencies: [.package(path: "../../Packages/OmiKit")],
                      targets: [.target(name: "WatchConnectivity"), .target(name: "WatchKit"),
                                .testTarget(name: "Checks", dependencies: ["WatchConnectivity", "WatchKit", .product(name: "OmiWatchKit", package: "OmiKit")])])
