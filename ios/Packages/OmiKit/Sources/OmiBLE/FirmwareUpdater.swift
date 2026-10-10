import Foundation
import OmiCapture
import OmiProtocol

/// Where a firmware update is. "Done" only once the pendant has restarted and reports the version.
public enum FirmwareUpdateState: Equatable, Sendable {
    case idle
    case preparing
    case uploading(sent: Int, total: Int)
    case confirming
    case restarting(target: String)
    case done(version: String)
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .preparing, .uploading, .confirming, .restarting: return true
        default: return false
        }
    }
}

/// Uploads a checked CV1 package over MCUmgr SMP, one request at a time: both images, then (only
/// if the pendant reports them) marks them to be installed and restarts it. Confined to the engine
/// queue. Nothing is marked for installation unless every image arrived whole.
final class FirmwareUpdater: @unchecked Sendable {
    let package: FirmwarePackage
    let target: String
    let session: DeviceSession
    let queue: DispatchQueue
    var onState: (FirmwareUpdateState) -> Void = { _ in }

    static let requestTimeout: TimeInterval = 8
    static let maxAttempts = 3
    static let sendRetryDelay: TimeInterval = 0.05

    private(set) var state: FirmwareUpdateState = .idle
    /// Some image is already marked to be installed at the next restart.
    private(set) var marked = false
    private var sequence: UInt8 = 0
    private var assembler = SMPAssembler()
    private var pending: (sequence: UInt8, data: Data, handler: (SMPMessage) -> Void)?
    private var token = 0
    private var attempts = 0
    private var sent = 0
    private var resetSent = false

    init(package: FirmwarePackage, target: String, session: DeviceSession, queue: DispatchQueue) {
        self.package = package
        self.target = target
        self.session = session
        self.queue = queue
    }

    func start() {
        set(.preparing)
        session.onSMP = { [weak self] data in self?.receive(data) }
        session.enableSMP { [weak self] error in
            guard let self else { return }
            if let error { return self.fail("the pendant's update service couldn't be opened: \(error.localizedDescription)") }
            self.upload(image: 0, offset: 0)
        }
    }

    /// The link dropped (or the session ended).
    func linkDropped() {
        pending = nil
        token += 1
        if resetSent, !state.isFinished { return set(.restarting(target: target)) }
        guard state.isActive, !resetSent else { return }
        fail(marked
             ? "the connection dropped after the update was marked to install; the pendant installs it the next time it restarts"
             : "the connection dropped during the update; nothing was installed")
    }

    // MARK: Steps

    private func upload(image i: Int, offset: Int) {
        guard i < package.images.count else { return checkUploaded() }
        let img = package.images[i]
        let bytes = img.image.data
        guard offset < bytes.count else { return upload(image: i + 1, offset: 0) }
        let n = SMPMessage.chunkSize(image: img.index, offset: offset, total: bytes.count, sha: img.image.hash,
                                     maximumWrite: session.info.mtu)
        guard n > 0 else { return fail("the Bluetooth packets are too small to update over (\(session.info.mtu) bytes)") }
        let chunk = bytes.subdata(in: offset..<min(bytes.count, offset + n))
        let msg = SMPMessage.upload(image: img.index, offset: offset, chunk: chunk, total: bytes.count, sha: img.image.hash, sequence: next())
        request(msg) { [weak self] r in
            guard let self else { return }
            guard r.rc == 0 else { return self.fail("the pendant refused image \(img.index) (error \(r.rc))") }
            guard let off = r.body["off"]?.int, off > offset, off <= bytes.count else {
                return self.fail("the pendant answered the upload unexpectedly")
            }
            self.sent += off - offset
            self.set(.uploading(sent: self.sent, total: self.package.totalBytes))
            self.upload(image: i, offset: off)
        }
    }

    /// Before marking anything: the pendant must report both uploaded images by their hashes.
    private func checkUploaded() {
        set(.confirming)
        request(.readImageState(sequence: next())) { [weak self] r in
            guard let self else { return }
            let slots = SMPImageSlot.parse(r.body)
            for img in self.package.images where !slots.contains(where: { $0.hash == img.image.hash }) {
                return self.fail("the pendant didn't report image \(img.index) after uploading it; nothing was installed")
            }
            self.confirm(0)
        }
    }

    private func confirm(_ i: Int) {
        guard i < package.images.count else { return reset() }
        let img = package.images[i]
        request(.confirm(hash: img.image.hash, sequence: next())) { [weak self] r in
            guard let self else { return }
            guard r.rc == 0 else { return self.fail("the pendant refused to install image \(img.index) (error \(r.rc))") }
            self.marked = true
            self.confirm(i + 1)
        }
    }

    private func reset() {
        resetSent = true
        request(.reset(sequence: next())) { [weak self] _ in
            guard let self else { return }
            self.set(.restarting(target: self.target))
        }
    }

    // MARK: Requests

    private func next() -> UInt8 {
        sequence &+= 1
        return sequence
    }

    private func request(_ msg: SMPMessage, handler: @escaping (SMPMessage) -> Void) {
        pending = (msg.sequence, msg.encoded(), handler)
        attempts = 0
        transmit()
    }

    private func transmit(flowRetries: Int = 0) {
        guard let p = pending else { return }
        token += 1
        let mine = token
        guard session.sendSMP(p.data) else {
            // CoreBluetooth's write-without-response queue is full, or the link went away.
            guard flowRetries < 100 else { return fail("the update couldn't be sent to the pendant") }
            queue.asyncAfter(deadline: .now() + Self.sendRetryDelay) { [weak self] in
                guard let self, self.token == mine else { return }
                self.transmit(flowRetries: flowRetries + 1)
            }
            return
        }
        attempts += 1
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            guard let self, self.token == mine, self.pending != nil else { return }
            if self.resetSent { return self.set(.restarting(target: self.target)) }  // it restarted before answering
            if self.attempts < Self.maxAttempts {
                self.assembler.reset()
                self.transmit()
            } else {
                self.fail("the pendant stopped answering during the update")
            }
        }
    }

    private func receive(_ data: Data) {
        guard let msg = assembler.append(data) else { return }
        guard let p = pending, msg.sequence == p.sequence else { return }  // a late answer to an earlier try
        pending = nil
        token += 1
        p.handler(msg)
    }

    private func set(_ s: FirmwareUpdateState) {
        guard s != state else { return }
        state = s
        onState(s)
    }

    private func fail(_ why: String) {
        pending = nil
        token += 1
        log(.error, "firmware", "update to \(target) failed: \(why)")
        set(.failed(why))
    }

    /// The pendant reconnected after the restart.
    func reconnected(reporting version: String?) {
        guard case .restarting = state else { return }
        if version == target {
            log(.info, "firmware", "pendant restarted on \(target)")
            set(.done(version: target))
        } else {
            set(.failed("the pendant restarted but reports firmware \(version ?? "unknown"), not \(target)"))
        }
    }

    func timedOutWaitingForRestart() {
        guard case .restarting = state else { return }
        set(.failed("the pendant hasn't reconnected since restarting; keep it near this iPhone, then check its firmware version"))
    }
}

extension FirmwareUpdateState {
    var isFinished: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }
}
