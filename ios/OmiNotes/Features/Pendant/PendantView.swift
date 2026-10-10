import OmiBLE
import OmiCapture
import SwiftUI

/// The pendant at a glance (approved design v4): the pendant with its battery ring and one centre
/// indicator, its name and an observed state line, then a short card of what matters now (an issue
/// with its fix, the iPhone's upload queue, audio collected from the pendant). Pendant actions and
/// diagnostics are one level down. Everything comes from `PendantSummary`, which states only what
/// the app has observed.
struct PendantView: View {
    let model: AppModel
    var onFix: (SystemHealth.Fix) -> Void
    @State private var page: Page?

    enum Page: Hashable { case manage, troubleshooting }

    /// Simulator screenshots only (debug builds): `-OmiNotesDebugPendantState normal|mid|charging|disconnected|unpaired|blocked`
    /// shows a synthetic state instead of the live one.
    private static var debugState: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "OmiNotesDebugPendantState")
        #else
        return nil
        #endif
    }

    /// The live summary, or (debug builds) a synthetic one and `true`.
    private func summary(_ now: Date) -> (PendantSummary, synthetic: Bool) {
        #if DEBUG
        if let name = Self.debugState, let fixture = PendantSummary.debugFixture(name, now: now) { return (fixture, true) }
        #endif
        return (PendantSummary.evaluate(snapshot: model.snapshot, server: model.server, status: model.serverStatus,
                                        statusAt: model.serverStatusAt, now: now, issues: model.issues), false)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let (p, synthetic) = summary(context.date)
            ScrollView {
                VStack(spacing: 0) {
                    #if DEBUG
                    if synthetic {
                        Text("SYNTHETIC PREVIEW · DEBUG").font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(Pendant.synthetic).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Pendant.syntheticBackground, in: .rect(cornerRadius: 6))
                    }
                    #endif
                    PendantHero(summary: p).padding(.top, 10)
                    VStack(spacing: 3) {
                        Text(p.name).font(.title2.weight(.bold)).tracking(-0.5)
                        Text(p.stateLine).font(.subheadline).foregroundStyle(Pendant.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.top, 20)
                    .accessibilityElement(children: .combine)
                    if !p.rows.isEmpty {
                        Card {
                            ForEach(Array(p.rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Divider().padding(.leading, 58) }
                                RowView(row: row, onFix: onFix)
                            }
                        }
                        .padding(.top, 18)
                    }
                    Card {
                        LinkRow(title: "Manage pendant") { page = .manage }
                        Divider().padding(.leading, 16)
                        LinkRow(title: "Troubleshooting") { page = .troubleshooting }
                    }
                    .padding(.top, 12)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Pendant.background.ignoresSafeArea())
            .foregroundStyle(Pendant.ink)
        }
        .navigationTitle("Pendant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Manage pendant", systemImage: "slider.horizontal.3") { page = .manage }
                    Button("Troubleshooting", systemImage: "stethoscope") { page = .troubleshooting }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .navigationDestination(item: $page) { page in
            switch page {
            case .manage: ManagePendantView(model: model)
            case .troubleshooting: DiagnosticsView(model: model)
            }
        }
    }
}

/// Colours of the approved design: light (approved v4) and its dark counterpart, following the
/// system appearance. Ring tones are a little brighter in dark so they stay legible on charcoal.
enum Pendant {
    static let background = Color(light: 0xf4f2ee, dark: 0x161513)
    static let halo = Color(light: 0xece3d1, dark: 0x2a2620)
    static let ink = Color(light: 0x1c1c1e, dark: 0xf2efe9)
    static let secondary = Color(light: 0x8a8578, dark: 0x9d988c)
    static let card = Color(light: 0xffffff, dark: 0x22201d, lightOpacity: 0.78, darkOpacity: 1)
    static let cardShadow = Color(light: 0x000000, dark: 0x000000, lightOpacity: 0.04, darkOpacity: 0.30)
    static let divider = Color(light: 0x000000, dark: 0xffffff, lightOpacity: 0.10, darkOpacity: 0.08)
    static let iconBackground = Color(light: 0xefece6, dark: 0x302d29)
    static let iconForeground = Color(light: 0x6e6a60, dark: 0xb8b2a6)
    static let warnBackground = Color(light: 0xfbe3cc, dark: 0x4a2c17)
    static let warnForeground = Color(light: 0xb4520e, dark: 0xf2a466)
    static let track = Color(light: 0xe4dfd6, dark: 0x34312c)
    static let unknownRing = Color(light: 0xd3cec4, dark: 0x57534c)
    static let healthy = Color(light: 0x5f9e74, dark: 0x6fb487)
    static let middle = Color(light: 0xc4952f, dark: 0xd8aa47)
    static let low = Color(light: 0xcc5a44, dark: 0xe06c55)
    static let lowText = Color(light: 0xb4432f, dark: 0xf08c76)
    static let indicatorOn = Color(light: 0x3cc46b, dark: 0x45d176)
    static let indicatorOff = Color(light: 0xb9b4aa, dark: 0x6b675f)
    static let chevron = Color(light: 0xc7c7cc, dark: 0x5c5850)
    /// The badge capsule floating on the ring.
    static let badge = Color(light: 0xffffff, dark: 0x2c2a26, lightOpacity: 0.94, darkOpacity: 0.96)
    static let badgeBorder = Color(light: 0x000000, dark: 0xffffff, lightOpacity: 0.06, darkOpacity: 0.08)
    /// The action pill ("Retry"): dark on light, light on dark.
    static let actionFill = Color(light: 0x1c1c1e, dark: 0xf2efe9)
    static let actionText = Color(light: 0xffffff, dark: 0x1c1c1e)
    // Pendant material: warm white ceramic in light, graphite in dark.
    static let shellHighlight = Color(light: 0xffffff, dark: 0x57544f)
    static let shellMid = Color(light: 0xf1efea, dark: 0x3a3834)
    static let shellEdge = Color(light: 0xd9d5cd, dark: 0x22211e)
    static let faceHighlight = Color(light: 0xfbfaf7, dark: 0x45423e)
    static let faceMid = Color(light: 0xebe8e1, dark: 0x32302c)
    static let faceEdge = Color(light: 0xe2ded5, dark: 0x2a2825)
    static let shellShadow = Color(light: 0x6b5f4a, dark: 0x000000, lightOpacity: 0.33, darkOpacity: 0.55)
    static let synthetic = Color(light: 0xa0784a, dark: 0xd9b07c)
    static let syntheticBackground = Color(light: 0xf3e6d3, dark: 0x3b2f20)

    static func ring(_ tone: PendantSummary.Battery.Tone) -> Color {
        switch tone {
        case .healthy: return healthy
        case .middle: return middle
        case .low: return low
        case .unknown: return unknownRing
        }
    }
}

extension Color {
    /// A colour that follows the system appearance (light/dark), from 0xRRGGBB values.
    init(light: UInt32, dark: UInt32, lightOpacity: Double = 1, darkOpacity: Double = 1) {
        func ui(_ hex: UInt32, _ alpha: Double) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
        }
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark, darkOpacity) : ui(light, lightOpacity) })
    }
}

/// The pendant illustration (no display: the badge and indicator are app overlays), its 300° battery
/// ring opening at the bottom where the battery badge sits, and one centre connection indicator.
private struct PendantHero: View {
    let summary: PendantSummary
    private let gauge = 300.0 / 360.0

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Pendant.halo, Pendant.halo.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 128))
                .frame(width: 256, height: 256)
            ring.frame(width: 216, height: 216)
            device
            BatteryBadge(battery: summary.battery).offset(y: 112)
        }
        .frame(width: 236, height: 248)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pendant. \(summary.connected ? "Connected" : summary.connectionTitle). \(BatteryBadge.label(summary.battery))")
    }

    @ViewBuilder private var ring: some View {
        if case .unknown = summary.battery {
            Circle().stroke(Pendant.unknownRing, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 7]))
        } else {
            ZStack {
                Circle().trim(from: 0, to: gauge).stroke(Pendant.track, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                Circle().trim(from: 0, to: gauge * fraction)
                    .stroke(Pendant.ring(summary.battery.tone), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            .rotationEffect(.degrees(120))
        }
    }

    private var fraction: Double {
        if case .level(let p, _, _) = summary.battery { return Double(max(0, min(p, 100))) / 100 }
        return 0
    }

    private var device: some View {
        let on = summary.connected
        return ZStack {
            Circle().fill(RadialGradient(colors: [Pendant.shellHighlight, Pendant.shellMid, Pendant.shellEdge],
                                         center: UnitPoint(x: 0.38, y: 0.30), startRadius: 0, endRadius: 92))
                .shadow(color: Pendant.shellShadow, radius: 16, y: 14)
                .shadow(color: .black.opacity(0.08), radius: 3, y: 3)
            Circle().fill(RadialGradient(colors: [Pendant.faceHighlight, Pendant.faceMid, Pendant.faceEdge],
                                         center: UnitPoint(x: 0.40, y: 0.32), startRadius: 0, endRadius: 60))
                .padding(19)
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            Circle().fill(on ? Pendant.indicatorOn : Pendant.indicatorOff)
                .frame(width: 9, height: 9)
                .shadow(color: (on ? Pendant.indicatorOn : .clear).opacity(0.8), radius: 4.5)
        }
        .frame(width: 132, height: 132)
        .saturation(on ? 1 : 0)
        .opacity(on ? 1 : 0.6)
    }
}

/// "82%", "46% · Charging", "Low · 12%" or "Battery unknown": readable without colour.
struct BatteryBadge: View {
    let battery: PendantSummary.Battery

    var body: some View {
        HStack(spacing: 6) {
            switch battery {
            case .unknown:
                Text("Battery unknown")
            case .level(let p, let charging, let low):
                BatteryIcon(fraction: Double(p) / 100, color: low ? Pendant.lowText : Pendant.ink.opacity(0.85))
                if charging { Image(systemName: "bolt.fill").font(.caption2) }
                Text(low ? "Low · \(p)%" : charging ? "\(p)% · Charging" : "\(p)%").monospacedDigit()
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Pendant.badge, in: .capsule)
        .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
        .overlay(Capsule().strokeBorder(Pendant.badgeBorder, lineWidth: 0.5))
    }

    private var color: Color {
        switch battery {
        case .unknown: return Pendant.secondary
        case .level(_, _, true): return Pendant.lowText
        case .level: return Pendant.ink
        }
    }

    static func label(_ battery: PendantSummary.Battery) -> String {
        switch battery {
        case .unknown(let reason): return "Battery unknown. \(reason)."
        case .level(let p, true, _): return "Battery \(p) percent, charging."
        case .level(let p, _, true): return "Battery low, \(p) percent."
        case .level(let p, _, _): return "Battery \(p) percent."
        }
    }
}

private struct BatteryIcon: View {
    let fraction: Double
    let color: Color

    var body: some View {
        HStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 3).strokeBorder(color, lineWidth: 1.4)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(color)
                        .frame(width: max(1.5, 15 * min(max(fraction, 0), 1)))
                        .padding(2.4)
                }
                .frame(width: 20, height: 10)
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 1.6, height: 3.5)
        }
        .accessibilityHidden(true)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .background(Pendant.card, in: .rect(cornerRadius: 20))
            .shadow(color: Pendant.cardShadow, radius: 1, y: 1)
    }
}

private struct RowView: View {
    let row: PendantSummary.Row
    var onFix: (SystemHealth.Fix) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        AdaptiveStack(vertical: typeSize.isAccessibilitySize, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(.subheadline.weight(.semibold))
                    if let detail = row.detail { Text(detail).font(.footnote).foregroundStyle(Pendant.secondary) }
                    if let progress = row.progress {
                        ProgressView(value: progress).tint(Pendant.ink).frame(maxWidth: 170).padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if let fix = row.fix {
                Button { onFix(fix) } label: {
                    Text(fix == .retryUploads ? "Retry" : fix.title).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                        .foregroundStyle(Pendant.actionText).background(Pendant.actionFill, in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 58)
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(row.attention ? Pendant.warnForeground : Pendant.iconForeground)
            .frame(width: 30, height: 30)
            .background(row.attention ? Pendant.warnBackground : Pendant.iconBackground, in: .rect(cornerRadius: 10))
            .accessibilityHidden(true)
    }

    private var symbol: String {
        if row.attention { return "exclamationmark" }
        switch row.kind {
        case .pendant: return "questionmark"
        case .phone: return "arrow.up"
        case .storage: return "tray.and.arrow.down"
        case .gestures: return "hand.tap"
        }
    }
}

private struct LinkRow: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.body)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Pendant.chevron)
            }
            .padding(.horizontal, 16).frame(minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pendant details, its settings and actions, kept off the main screen. Forget keeps its confirmation.
struct ManagePendantView: View {
    let model: AppModel
    @State private var controls: PendantControlsModel

    init(model: AppModel) {
        self.model = model
        _controls = State(initialValue: PendantControlsModel(engine: model.engine))
    }

    var body: some View {
        List {
            PendantControlsSection(model: model, controls: controls)
            PendantButtonSection(model: model)
            PendantDeviceSection(snapshot: model.snapshot)
            DeviceSettingsSection(model: model)
            Section {
                Link(destination: URL(string: "https://www.omi.me/pages/charging-omi")!) {
                    Label("Charging help", systemImage: "bolt.badge.questionmark")
                }
            }
        }
        .navigationTitle("Manage pendant")
    }
}
