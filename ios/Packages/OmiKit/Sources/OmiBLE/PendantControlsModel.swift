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
    /// Changes settle this long before anything is written (a slider moves through many values).
    var settleDelay: Duration = .milliseconds(300)
    /// Writes one value and reports what the pendant then has (the engine; replaced in tests).
    var write: (PendantSetting, Int, @escaping @Sendable (Result<Int, Error>) -> Void) -> Void
    /// The latest value chosen and not yet written, per setting.
    private var wanted: [PendantSetting: Int] = [:]
    private var settling: [PendantSetting: Task<Void, Never>] = [:]
    private var writing: Set<PendantSetting> = []

    public init(engine: OmiEngine) {
        self.engine = engine
        write = { [engine] setting, value, done in engine.changePendantSetting(setting, to: value, completion: done) }
    }

    public func status(of setting: PendantSetting) -> Status { status[setting] ?? .idle }

    /// Shows "Saving…" at once; writes only the value the changes settle on, one write at a time.
    public func change(_ setting: PendantSetting, to value: Int) {
        status[setting] = .saving(value)
        wanted[setting] = value
        settling[setting]?.cancel()
        settling[setting] = Task { [weak self, settleDelay] in
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled else { return }
            self?.flush(setting)
        }
    }

    private func flush(_ setting: PendantSetting) {
        guard !writing.contains(setting), let value = wanted.removeValue(forKey: setting) else { return }
        writing.insert(setting)
        write(setting, value) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.writing.remove(setting)
                if let next = self.wanted[setting] {  // chosen meanwhile: that one is what counts
                    self.status[setting] = .saving(next)
                    self.flush(setting)
                    return
                }
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
