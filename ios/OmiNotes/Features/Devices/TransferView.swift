import OmiBLE
import SwiftUI

/// Words for the transfer screens (one place, so the card and the page say the same thing). The
/// Transfers screen and its Devices card read in Chinese (Alan's wording); the lines themselves come
/// from `TransferSummary`, where they are tested.
enum TransferText {
    /// Details only: "N 个文件" (counts never appear on the main screen).
    static func count(_ n: Int, _ unit: String) -> String { "\(n.formatted()) 个\(unit)" }

    /// The live summary (or, debug builds, the `-OmiNotesDebugTransferState` synthetic fixture).
    @MainActor static func summary(_ model: AppModel, watchInstalled: Bool?, now: Date) -> TransferSummary {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "OmiNotesDebugTransferState"),
           let fixture = TransferSummary.debugFixture(name, now: now) { return fixture }
        #endif
        return model.transfers(watchInstalled: watchInstalled, now: now)
    }

    /// Simulator screenshots only (debug builds): `-OmiNotesDebugTransferExpanded YES` opens the folds.
    static var debugExpanded: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "OmiNotesDebugTransferExpanded")
        #else
        return false
        #endif
    }

    static var synthetic: Bool {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "OmiNotesDebugTransferState") != nil
        #else
        return false
        #endif
    }

    static let explanations = [
        "Watch → iPhone：这台 iPhone 已安全保存的部分，占它们加上手表最近报告的待发部分的比例。iOS 不报告传输途中的进度，所以这条进度条只在手表报告时（录音时每几分钟一次）和收到一部分时移动。",
        "iPhone → 服务器：自打开 App 以来服务器确认收到的录音，占它加上这里仍在排队的录音的比例。速度来自本页打开期间上传自身的进度报告。剩余时间按当前速度估算；录音在继续、速度会变，只作粗略参考。",
        "在后台由 iOS 决定何时上传，所以那时这里的数字不是实时的。“已交给 iOS”是 iOS 可能尚未开始的上传。每个文件在服务器确认已保存时才算送达；在此之前一直保留在这台 iPhone 上。",
        "服务器上的录音还不是笔记：服务器转写并总结之后，笔记才会出现。",
    ]
}

/// Devices: one quiet card; under its title only a problem, an estimate, or "全部已发送".
struct TransferCardView: View {
    let model: AppModel
    let watchInstalled: Bool?
    var open: () -> Void

    var body: some View {
        // re-evaluated every second: a rate stops showing as soon as bytes stop
        TimelineView(.periodic(from: .now, by: 1)) { context in
            TransferCardRow(summary: TransferText.summary(model, watchInstalled: watchInstalled, now: context.date),
                            now: context.date, open: open)
        }
    }
}

/// The card from one summary (no model).
struct TransferCardRow: View {
    let summary: TransferSummary
    let now: Date
    var open: () -> Void

    var body: some View {
        let line = summary.cardLine(now: now)
        Card {
            Button(action: open) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pendant.iconForeground)
                        .frame(width: 30, height: 30).background(Pendant.iconBackground, in: .rect(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("传输").font(.headline)
                        if let line {
                            Text(line.text).font(.subheadline.monospacedDigit())
                                .foregroundStyle(line.attention ? Pendant.warnForeground : Pendant.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Pendant.chevron)
                }
                .padding(.horizontal, 16).padding(.vertical, 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("打开传输详情")
        }
    }
}

/// One bar per hop, a problem line only when something is wrong, then the counters and
/// explanations folded away. Live only while open; every number comes from its own source (the
/// Watch's report, this iPhone's uploads, the server's last status).
struct TransferDetailView: View {
    let model: AppModel
    let watchInstalled: Bool?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            TransferDetailContent(summary: TransferText.summary(model, watchInstalled: watchInstalled, now: context.date),
                                  now: context.date, synthetic: TransferText.synthetic)
        }
        .navigationTitle("传输")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The page from one summary (no model), so a fixed summary renders it too. No heading, state
/// label, percentage or count on the main screen: the bars show progress; counts live in Details.
struct TransferDetailContent: View {
    let summary: TransferSummary
    let now: Date
    let synthetic: Bool
    @AppStorage(SyncActivityCoordinator.optOutKey) private var lockScreenOff = false
    @State private var showDetails: Bool
    @State private var showHow: Bool

    init(summary: TransferSummary, now: Date, synthetic: Bool, expanded: Bool = TransferText.debugExpanded) {
        self.summary = summary
        self.now = now
        self.synthetic = synthetic
        _showDetails = State(initialValue: expanded)
        _showHow = State(initialValue: expanded)
    }

    var body: some View {
        let t = summary
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if synthetic {
                    Text("SYNTHETIC PREVIEW · DEBUG").font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
                        .foregroundStyle(Pendant.synthetic).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Pendant.syntheticBackground, in: .rect(cornerRadius: 6)).frame(maxWidth: .infinity)
                }
                if let problem = t.problemLine(now: now) {
                    Label(problem, systemImage: "exclamationmark.circle").font(.subheadline.weight(.semibold))
                        .foregroundStyle(Pendant.warnForeground).padding(.horizontal, 4)
                }
                if t.watch.inUse != false { hop("Watch → iPhone", fraction: t.watchFraction, line: t.watchLine(now: now)) }
                hop("iPhone → 服务器", fraction: t.phoneFraction, line: t.phoneLine)
                if let server = t.serverLine(now: now) {
                    Text(server).font(.footnote).foregroundStyle(Pendant.secondary).padding(.horizontal, 4)
                }
                fold("详情", isOn: $showDetails) { details(t) }
                fold("说明", isOn: $showHow) { explanations }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
        }
        .background(Pendant.background.ignoresSafeArea())
        .foregroundStyle(Pendant.ink)
    }

    // MARK: hops

    private func hop(_ title: String, fraction: Double?, line: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                bar(fraction)
                Text(line).font(.footnote.monospacedDigit()).foregroundStyle(Pendant.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .accessibilityElement(children: .combine)
            .accessibilityValue(fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "")
        }
    }

    /// A plain track; empty (no fill) when the fraction isn't known.
    private func bar(_ fraction: Double?) -> some View {
        Capsule().fill(Pendant.track).frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(Pendant.ink).frame(width: max(fraction.map { $0 > 0 ? 6 : 0 } ?? 0, g.size.width * min(max(fraction ?? 0, 0), 1)))
                }
            }
            .accessibilityHidden(true)
    }

    // MARK: folded

    private func fold(_ title: String, isOn: Binding<Bool>, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { isOn.wrappedValue.toggle() } } label: {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Pendant.chevron)
                        .rotationEffect(.degrees(isOn.wrappedValue ? 90 : 0))
                }
                .padding(.horizontal, 4).padding(.top, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOn.wrappedValue ? "已展开" : "已收起")
            if isOn.wrappedValue { content() }
        }
    }

    /// One line per fact: the label on the left, a short value on the right, never wrapped.
    private func row(_ title: String, _ value: String?, attention: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(Pendant.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(value ?? "未知").monospacedDigit().lineLimit(1).layoutPriority(1)
                .foregroundStyle(attention ? Pendant.warnForeground : value == nil ? Pendant.secondary : Pendant.ink)
        }
        .font(.subheadline)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func ago(_ date: Date) -> String { TransferSummary.agoText(date, now: now) }

    /// Every counter, including the counts the main screen leaves out.
    @ViewBuilder private func details(_ t: TransferSummary) -> some View {
        let p = t.phone, w = t.watch, s = t.server
        let counting = p.since != nil
        Card {
            VStack(spacing: 0) {
                row("速度", p.rate.map(TransferSummary.rateText) ?? (counting ? "无" : nil))
                row("排队文件", TransferText.count(p.queuedFiles, "文件"))
                row("排队大小", Fmt.bytes(p.queuedBytes))
                if p.queuedAudioFiles > 0 { row("排队录音", TransferSummary.durationText(Int(p.queuedAudioSeconds.rounded()))) }
                if p.queuedAudioUnknown > 0 { row("时长未知的录音", TransferText.count(p.queuedAudioUnknown, "文件")) }
                row("已交给 iOS", counting ? TransferText.count(p.inFlightUploads, "上传") : nil)
                if counting, p.inFlightTotal > 0 { row("这些上传中", "\(Fmt.bytes(p.inFlightSent)) / \(Fmt.bytes(p.inFlightTotal))") }
                row(p.since.map { "\($0.formatted(date: .omitted, time: .shortened)) 起已发送" } ?? "已发送", counting ? Fmt.bytes(p.networkBytes) : nil)
                row("已确认录音", counting ? "\(TransferText.count(p.deliveredAudioFiles, "文件")) · \(Fmt.bytes(p.deliveredAudioBytes))" : nil)
                if p.deliveredOtherFiles > 0 { row("已确认其他", TransferText.count(p.deliveredOtherFiles, "文件")) }
                if p.retryingAttempts > 0 { row("失败，将重试", "\(p.retryingAttempts.formatted()) 次", attention: true) }
                if p.heldAttempts > 0 { row("已停止的尝试", "\(p.heldAttempts.formatted()) 次", attention: true) }
                if p.keptAside > 0 { row("已搁置", TransferText.count(p.keptAside, "文件"), attention: true) }
            }
            .padding(.vertical, 4)
        }
        if w.inUse == true {
            Card {
                VStack(spacing: 0) {
                    row("手表报告", w.reportAt.map { (w.reportFresh ? "" : "已过时 · ") + ago($0) })
                    if w.reportAt != nil {
                        if let parts = w.waitingParts { row("手表上的待发部分", TransferText.count(parts, "部分")) }
                        if let seconds = w.waitingSeconds { row("手表上的录音", TransferSummary.durationText(seconds)) }
                        if w.recheckParts > 0 { row("其中重新核对", TransferText.count(w.recheckParts, "较早部分")) }
                        row("无法发送的部分", w.keptOnWatch.map { TransferText.count($0, "部分") }, attention: (w.keptOnWatch ?? 0) > 0)
                    }
                    row("已从手表收到", TransferText.count(w.receivedOnPhone, "部分"))
                    row("上次收到", w.lastReceivedAt.map(ago) ?? "启动后未收到")
                    if w.converting > 0 { row("准备中", TransferText.count(w.converting, "部分")) }
                    row("排队中的手表录音", TransferText.count(w.waitingForServer, "文件"))
                }
                .padding(.vertical, 4)
            }
        }
        Card {
            VStack(spacing: 0) {
                row("服务器检查", s.checkedAt.map(ago))
                row("待处理录音", s.chunksPending.map { $0.formatted() })
                row("待处理对话", s.conversationsPending.map { $0.formatted() })
                row("上一条笔记", s.lastNoteAt.map(ago))
            }
            .padding(.vertical, 4)
        }
        if SyncActivityCoordinator.available {
            Card {
                Toggle("在锁定屏幕上显示同步", isOn: Binding(get: { !lockScreenOff }, set: { lockScreenOff = !$0 }))
                    .font(.subheadline).padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    private var explanations: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(TransferText.explanations, id: \.self) { text in
                Text(text).font(.footnote).foregroundStyle(Pendant.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }
}
