// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmiKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OmiProtocol", targets: ["OmiProtocol"]),
        .library(name: "OmiCapture", targets: ["OmiCapture"]),
        .library(name: "OmiBLE", targets: ["OmiBLE"]),
    ],
    targets: [
        // Pure wire formats: GATT ids, ring protocol, envelope, CRC32. No I/O.
        .target(name: "OmiProtocol"),
        // Durable capture: journal, chunks, outbox, uploader, ring sync, retention.
        .target(name: "OmiCapture", dependencies: ["OmiProtocol"]),
        // CoreBluetooth, per-connection sequence, simulated device, app engine.
        .target(name: "OmiBLE", dependencies: ["OmiProtocol", "OmiCapture"]),

        .testTarget(name: "OmiProtocolTests", dependencies: ["OmiProtocol"]),
        .testTarget(
            name: "OmiCaptureTests",
            dependencies: ["OmiCapture", "OmiProtocol"],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "OmiBLETests", dependencies: ["OmiBLE", "OmiCapture", "OmiProtocol"]),
    ]
)
