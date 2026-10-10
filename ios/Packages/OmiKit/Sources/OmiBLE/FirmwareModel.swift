import Foundation
import OmiProtocol

/// Checking for, downloading and installing pendant firmware (Manage pendant ▸ Firmware). What is
/// installed is only ever the official Omi release for exactly the offered version, checked here
/// before anything is sent; the engine does the update and confirms it by the version the pendant
/// reports after restarting.
@MainActor
@Observable
public final class FirmwareModel {
    public enum Check: Equatable, Sendable {
        case idle, checking
        case upToDate(String)
        case available(FirmwareRelease)
        case failed(String)
    }

    public enum Prepare: Equatable, Sendable {
        case idle, downloading, checkingPackage
        case failed(String)
    }

    /// GET a URL: body and HTTP status.
    public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    public private(set) var check: Check = .idle
    /// The newest published release (for "reinstall / roll back to stable").
    public private(set) var stable: FirmwareRelease?
    public private(set) var prepare: Prepare = .idle
    private let engine: OmiEngine
    private let fetch: Fetch

    public init(engine: OmiEngine, fetch: @escaping Fetch = FirmwareModel.urlSessionFetch) {
        self.engine = engine
        self.fetch = fetch
    }

    public static let urlSessionFetch: Fetch = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Asks the Omi backend for a newer release than the pendant's, and for the latest stable one.
    public func checkForUpdate(_ device: DeviceSession.Info?) async {
        guard let d = device, let current = d.firmwareRevision else { check = .failed("Connect the pendant to check its firmware."); return }
        guard d.modelNumber == FirmwareRelease.cv1Model else { check = .failed("Updates here are for the Omi CV 1 only."); return }
        check = .checking
        do {
            let (data, status) = try await fetch(FirmwareRelease.latestURL(model: FirmwareRelease.cv1Model, firmware: current,
                                                                           hardware: d.hardwareRevision, manufacturer: d.manufacturer))
            switch status {
            case 200:
                if let r = FirmwareRelease(omiAPI: data) { check = .available(r) } else { check = .failed("Omi's update service answered unexpectedly.") }
            case 404: check = .upToDate(current)  // "No suitable firmware update found"
            default: check = .failed("Omi's update service answered \(status).")
            }
        } catch {
            check = .failed("Couldn't reach Omi's update service: \(error.localizedDescription)")
        }
        if let (data, status) = try? await fetch(FirmwareRelease.stableURL(model: FirmwareRelease.cv1Model)), status == 200 {
            stable = FirmwareRelease(omiAPI: data)
        }
    }

    /// Downloads, checks and installs a release. Every failure before the pendant is touched says so.
    public func install(_ release: FirmwareRelease, current: String?) async {
        if let why = release.blocker(installedOn: FirmwareVersion(current)) { prepare = .failed("Can't install \(release.version): \(why)."); return }
        if let why = engine.firmwareUpdateBlocker() { prepare = .failed(why); return }
        prepare = .downloading
        do {
            let (data, status) = try await fetch(release.zipURL)
            guard status == 200 else { prepare = .failed("The download failed (\(status)). Nothing was sent to the pendant."); return }
            prepare = .checkingPackage
            let package = try FirmwarePackage(zip: data)
            prepare = .idle
            engine.installFirmware(package, version: release.version)
        } catch {
            let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            prepare = .failed("The update wasn't installed: \(why). Nothing was sent to the pendant.")
        }
    }

    public func dismissResult() {
        prepare = .idle
        engine.clearFirmwareResult()
    }
}
