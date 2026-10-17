import OmiBLE
import OmiWatchKit
import SwiftUI
import WatchConnectivity

/// The Devices tab: one compact card per device in use (pendant, then Apple Watch), each opening its
/// own page. Both can record at the same time. A device not set up gets a quiet row, not a card.
/// Problems show on the device they concern; queues and diagnostics stay on the device pages.
struct DevicesView: View {
    let model: AppModel
    var onFix: (SystemHealth.Fix) -> Void
    @State private var page: DevicePage? = DevicesView.initialPage
    /// The last request shown (so returning to the tab doesn't reopen the page).
    @MainActor private static var shownRequests = 0

    private func openRequestedWatchPage() {
        guard model.watchPageRequests != Self.shownRequests else { return }
        Self.shownRequests = model.watchPageRequests
        page = .watch
    }

    /// Simulator screenshots only (debug builds): `-OmiNotesDebugDevicePage pendant|watch` opens that page.
    static var initialPage: DevicePage? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "OmiNotesDebugDevicePage") {
        case "pendant": return .pendant
        case "watch": return .watch
        default: return nil
        }
        #else
        return nil
        #endif
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let pendant = DevicesView.pendant(model, context.date)
            let watch = DevicesView.watch(model, context.date)
            let layout = DeviceLayout.arrange(pendantPaired: pendant.summary.paired, watchConfigured: watch.summary.configured)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    #if DEBUG
                    if pendant.synthetic || watch.synthetic { SyntheticBadge().frame(maxWidth: .infinity) }
                    #endif
                    ForEach(layout.cards, id: \.self) { device in
                        switch device {
                        case .pendant: PendantCardView(summary: pendant.summary, onFix: onFix) { page = .pendant }
                        case .watch: WatchCardView(summary: watch.summary) { page = .watch }
                        }
                    }
                    if layout.cards.isEmpty {
                        Text("Record with an Omi pendant, your Apple Watch, or both. Their audio comes to this iPhone and becomes notes on your server.")
                            .font(.subheadline).foregroundStyle(Pendant.secondary).padding(.horizontal, 4).padding(.bottom, 2)
                    }
                    if !layout.setup.isEmpty {
                        Card {
                            ForEach(Array(layout.setup.enumerated()), id: \.element) { index, device in
                                if index > 0 { Divider().padding(.leading, 58) }
                                switch device {
                                case .pendant: SetupRow(title: "Add a pendant", symbol: "plus") { onFix(.pairDevice) }
                                case .watch: SetupRow(title: "Set up Apple Watch", symbol: "applewatch") { page = .watch }
                                }
                            }
                        }
                        .padding(.top, layout.cards.isEmpty ? 0 : 6)
                    }
                    if layout.cards.count == 2 {
                        Text("Both can record at the same time. Each sends its audio through this iPhone.")
                            .font(.footnote).foregroundStyle(Pendant.secondary).padding(.horizontal, 4)
                    }
                    // where audio is right now: Watch → iPhone → server, each from its own source
                    if model.snapshot.serverConfigured || !layout.cards.isEmpty || model.snapshot.outbox.pendingCount > 0 {
                        TransferCardView(model: model, watchInstalled: Self.watchAppInstalled) { page = .transfers }
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
            }
            .background(Pendant.background.ignoresSafeArea())
            .foregroundStyle(Pendant.ink)
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        // a tapped Watch alert: cold launch (the view appears after the request) or warm
        .onAppear(perform: openRequestedWatchPage)
        .onChange(of: model.watchPageRequests) { openRequestedWatchPage() }
        .navigationDestination(item: $page) { page in
            DevicePageView(page: page, model: model, onFix: onFix)
        }
    }

    /// The pendant's summary (or, debug builds, the `-OmiNotesDebugPendantState` fixture).
    static func pendant(_ model: AppModel, _ now: Date) -> (summary: PendantSummary, synthetic: Bool) {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "OmiNotesDebugPendantState"),
           let fixture = PendantSummary.debugFixture(name, now: now) { return (fixture, true) }
        #endif
        return (PendantSummary.evaluate(snapshot: model.snapshot, server: model.server, status: model.serverStatus,
                                        statusAt: model.serverStatusAt, now: now, issues: model.issues), false)
    }

    /// The Watch's summary (or, debug builds, the `-OmiNotesDebugWatchState` fixture).
    static func watch(_ model: AppModel, _ now: Date) -> (summary: WatchSummary, report: WatchReport?, synthetic: Bool) {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "OmiNotesDebugWatchState"),
           let fixture = WatchSummary.debugFixture(name, now: now) { return (fixture.summary, fixture.report, true) }
        #endif
        let s = model.snapshot
        return (WatchSummary.evaluate(installed: watchAppInstalled, report: s.watchReport, lastReceivedAt: s.watchLastReceivedAt, now: now),
                s.watchReport, false)
    }

    /// The Watch app is installed on a paired Watch; nil until WatchConnectivity has activated.
    static var watchAppInstalled: Bool? {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return nil }
        return WCSession.default.isPaired && WCSession.default.isWatchAppInstalled
    }
}

enum DevicePage: Hashable { case pendant, watch, transfers }

/// A device's own page; Settings opens the same pages.
struct DevicePageView: View {
    let page: DevicePage
    let model: AppModel
    var onFix: (SystemHealth.Fix) -> Void

    var body: some View {
        switch page {
        case .pendant: PendantView(model: model, onFix: onFix)
        case .watch: WatchDetailView(model: model)
        case .transfers: TransferDetailView(model: model, watchInstalled: DevicesView.watchAppInstalled)
        }
    }
}

#if DEBUG
private struct SyntheticBadge: View {
    var body: some View {
        Text("SYNTHETIC PREVIEW · DEBUG").font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
            .foregroundStyle(Pendant.synthetic).padding(.horizontal, 7).padding(.vertical, 2)
            .background(Pendant.syntheticBackground, in: .rect(cornerRadius: 6))
    }
}
#endif

// MARK: Cards

private struct DeviceCardShell<Art: View>: View {
    let name: String
    let state: String
    let stateColor: Color?
    let detail: String?
    var detailColor: Color = Pendant.secondary
    @ViewBuilder var art: () -> Art
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                art().frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    HStack(spacing: 6) {
                        if let stateColor { Circle().fill(stateColor).frame(width: 7, height: 7) }
                        Text(state).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }
                    // never cut off: the end of the line ("reported 2 hours ago") is what matters
                    if let detail { Text(detail).font(.footnote).foregroundStyle(detailColor).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Pendant.chevron)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(name)")
    }
}

private struct PendantCardView: View {
    let summary: PendantSummary
    var onFix: (SystemHealth.Fix) -> Void
    var open: () -> Void

    var body: some View {
        Card {
            DeviceCardShell(name: summary.name, state: state, stateColor: summary.connected ? Pendant.indicatorOn : nil,
                            detail: battery, detailColor: lowBattery ? Pendant.lowText : Pendant.secondary,
                            art: { MiniPendant(on: summary.connected) }, action: open)
            // a problem shows here, on its device; everything else is on the pendant's page
            if let issue = summary.rows.first(where: \.attention) {
                Divider().padding(.leading, 86)
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Pendant.warnForeground).frame(width: 22, height: 22)
                        .background(Pendant.warnBackground, in: .rect(cornerRadius: 7))
                    Text(issue.title).font(.footnote.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let fix = issue.fix {
                        Button { onFix(fix) } label: {
                            Text(fix == .retryUploads ? "Retry" : fix.title).font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .foregroundStyle(Pendant.actionText).background(Pendant.actionFill, in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 86).padding(.trailing, 16).padding(.vertical, 10)
            }
        }
    }

    private var state: String {
        // the state line before its "·" detail: "Recording", "Not connected", "Connected"
        summary.stateLine.components(separatedBy: " · ").first ?? summary.stateLine
    }

    private var lowBattery: Bool {
        if case .level(_, false, true) = summary.battery { return true }
        return false
    }

    private var battery: String? {
        switch summary.battery {
        case .unknown: return nil
        case .level(let p, true, _): return "Battery \(p)% · Charging"
        case .level(let p, _, true): return "Battery low · \(p)%"
        case .level(let p, _, _): return "Battery \(p)%"
        }
    }
}

private struct WatchCardView: View {
    let summary: WatchSummary
    var open: () -> Void

    var body: some View {
        Card {
            DeviceCardShell(name: "Apple Watch", state: summary.title, stateColor: dot, detail: summary.detail,
                            art: { MiniWatch(recording: summary.tone == .recording) }, action: open)
        }
    }

    private var dot: Color? {
        switch summary.tone {
        case .recording: return Pendant.low
        case .attention: return Pendant.middle
        case .quiet: return nil
        }
    }
}

private struct SetupRow: View {
    let title: String
    let symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Pendant.iconForeground)
                    .frame(width: 30, height: 30).background(Pendant.iconBackground, in: .rect(cornerRadius: 10))
                Text(title).font(.body).foregroundStyle(Pendant.secondary)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Pendant.chevron)
            }
            .padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Illustrations (small, in the pendant's materials)

struct MiniPendant: View {
    let on: Bool

    var body: some View {
        ZStack {
            Circle().fill(Pendant.halo.opacity(0.7))
            Circle().fill(RadialGradient(colors: [Pendant.shellHighlight, Pendant.shellMid, Pendant.shellEdge],
                                         center: UnitPoint(x: 0.38, y: 0.30), startRadius: 0, endRadius: 24))
                .frame(width: 36, height: 36)
                .shadow(color: Pendant.shellShadow, radius: 4, y: 3)
            Circle().fill(RadialGradient(colors: [Pendant.faceHighlight, Pendant.faceMid], center: UnitPoint(x: 0.4, y: 0.3),
                                         startRadius: 0, endRadius: 14))
                .frame(width: 26, height: 26)
            Circle().fill(on ? Pendant.indicatorOn : Pendant.indicatorOff).frame(width: 4, height: 4)
        }
        .saturation(on ? 1 : 0)
    }
}

struct MiniWatch: View {
    let recording: Bool
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Circle().fill(Pendant.halo.opacity(0.7))
            RoundedRectangle(cornerRadius: 5 * scale).fill(Pendant.shellEdge).frame(width: 16 * scale, height: 46 * scale)
            RoundedRectangle(cornerRadius: 9 * scale)
                .fill(LinearGradient(colors: [Pendant.shellHighlight, Pendant.shellMid], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 28 * scale, height: 33 * scale)
                .shadow(color: Pendant.shellShadow, radius: 3 * scale, y: 2 * scale)
            RoundedRectangle(cornerRadius: 6.5 * scale).fill(Color(light: 0x24221f, dark: 0x0e0d0c)).frame(width: 22 * scale, height: 27 * scale)
            Circle().fill(recording ? Pendant.low : Pendant.indicatorOff).frame(width: 5 * scale, height: 5 * scale)
        }
    }
}
