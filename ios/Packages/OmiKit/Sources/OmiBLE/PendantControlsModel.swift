import Foundation
import OmiProtocol

/// The pendant's settings screen: what is being changed and how it went. The values themselves are
/// only ever the ones read from the pendant (`EngineSnapshot.device.settings`); a requested value is
/// shown as "Saving…", never as the pendant's.
@MainActor
@Observable
public final class PendantControlsModel {
    public enum Status: Equatable, Sendable {
        case idle
        case saving(Int)
        case saved(Int)
        case failed(String)
    }

    public enum FindStatus: Equatable, Sendable {
        case idle, vibrating, done
        case failed(String)
    }

    public private(set) var status: [PendantSetting: Status] = [:]
    public private(set) var find: FindStatus = .idle
    private let engine: OmiEngine
    private var attempt: [PendantSetting: Int] = [:]

    public init(engine: OmiEngine) { self.engine = engine }

    public func status(of setting: PendantSetting) -> Status { status[setting] ?? .idle }

    public func change(_ setting: PendantSetting, to value: Int) {
        let n = (attempt[setting] ?? 0) + 1
        attempt[setting] = n
        status[setting] = .saving(value)
        engine.changePendantSetting(setting, to: value) { result in
            MainActor.assumeIsolated {
                guard self.attempt[setting] == n else { return }  // a later change owns the status
                switch result {
                case .success(let reported): self.status[setting] = .saved(reported)
                case .failure(let error): self.status[setting] = .failed(Self.describe(error))
                }
            }
        }
    }

    public func findPendant() {
        guard find != .vibrating else { return }
        find = .vibrating
        engine.findPendant { error in
            MainActor.assumeIsolated { self.find = error.map { .failed(Self.describe($0)) } ?? .done }
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
