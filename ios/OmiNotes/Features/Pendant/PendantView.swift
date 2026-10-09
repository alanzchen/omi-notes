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
                                        statusAt: model.serverStatusAt, now: now), false)
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
            // The warm canvas is a fixed light design: its text, dividers and controls use the light
            // scheme so they stay readable in Dark Mode. Pushed pages keep the system's scheme.
            .environment(\.colorScheme, .light)
        }
        .navigationTitle("Pendant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.light, for: .navigationBar)
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

/// Colours of the approved design.
enum Pendant {
    static let background = Color(red: 0.957, green: 0.949, blue: 0.933)  // #f4f2ee
    static let secondary = Color(red: 0.541, green: 0.522, blue: 0.471)   // #8a8578
    static let card = Color.white.opacity(0.78)
    static let iconBackground = Color(red: 0.937, green: 0.925, blue: 0.902)  // #efece6
    static let iconForeground = Color(red: 0.431, green: 0.416, blue: 0.376)  // #6e6a60
    static let warnBackground = Color(red: 0.984, green: 0.890, blue: 0.800)  // #fbe3cc
    static let warnForeground = Color(red: 0.706, green: 0.322, blue: 0.055)  // #b4520e
    static let track = Color(red: 0.894, green: 0.875, blue: 0.839)       // #e4dfd6
    static let unknownRing = Color(red: 0.827, green: 0.808, blue: 0.769) // #d3cec4
    static let healthy = Color(red: 0.373, green: 0.620, blue: 0.455)     // #5f9e74
    static let middle = Color(red: 0.769, green: 0.584, blue: 0.184)      // #c4952f
    static let low = Color(red: 0.800, green: 0.353, blue: 0.267)         // #cc5a44
    static let lowText = Color(red: 0.706, green: 0.263, blue: 0.184)     // #b4432f
    static let indicatorOn = Color(red: 0.235, green: 0.769, blue: 0.420) // #3cc46b
    static let indicatorOff = Color(red: 0.725, green: 0.706, blue: 0.667) // #b9b4aa
    static let synthetic = Color(red: 0.627, green: 0.471, blue: 0.290)
    static let syntheticBackground = Color(red: 0.953, green: 0.902, blue: 0.827)

    static func ring(_ tone: PendantSummary.Battery.Tone) -> Color {
        switch tone {
        case .healthy: return healthy
        case .middle: return middle
        case .low: return low
        case .unknown: return unknownRing
        }
    }
}

/// The pendant illustration (no display: the badge and indicator are app overlays), its 300° battery
/// ring opening at the bottom where the battery badge sits, and one centre connection indicator.
private struct PendantHero: View {
    let summary: PendantSummary
    private let gauge = 300.0 / 360.0

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(red: 0.925, green: 0.890, blue: 0.820), Pendant.background.opacity(0)],
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
            Circle().fill(RadialGradient(colors: [.white, Color(red: 0.945, green: 0.937, blue: 0.918), Color(red: 0.851, green: 0.835, blue: 0.804)],
                                         center: UnitPoint(x: 0.38, y: 0.30), startRadius: 0, endRadius: 92))
                .shadow(color: Color(red: 0.42, green: 0.37, blue: 0.29).opacity(0.33), radius: 16, y: 14)
                .shadow(color: .black.opacity(0.08), radius: 3, y: 3)
            Circle().fill(RadialGradient(colors: [Color(red: 0.984, green: 0.980, blue: 0.969), Color(red: 0.922, green: 0.910, blue: 0.882),
                                                  Color(red: 0.886, green: 0.871, blue: 0.835)],
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
                BatteryIcon(fraction: Double(p) / 100, color: low ? Pendant.lowText : Color(white: 0.23))
                if charging { Image(systemName: "bolt.fill").font(.caption2) }
                Text(low ? "Low · \(p)%" : charging ? "\(p)% · Charging" : "\(p)%").monospacedDigit()
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(.white.opacity(0.94), in: .capsule)
        .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
        .overlay(Capsule().strokeBorder(.black.opacity(0.06), lineWidth: 0.5))
    }

    private var color: Color {
        switch battery {
        case .unknown: return Pendant.secondary
        case .level(_, _, true): return Pendant.lowText
        case .level: return Color(white: 0.11)
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
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
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
                        ProgressView(value: progress).tint(Color(white: 0.11)).frame(maxWidth: 170).padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if let fix = row.fix {
                Button { onFix(fix) } label: {
                    Text(fix == .retryUploads ? "Retry" : fix.title).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                        .foregroundStyle(.white).background(Color(white: 0.11), in: .capsule)
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
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color(white: 0.78))
            }
            .padding(.horizontal, 16).frame(minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pendant details and actions, kept off the main screen. Forget keeps its confirmation.
struct ManagePendantView: View {
    let model: AppModel

    var body: some View {
        List {
            PendantDeviceSection(snapshot: model.snapshot)
            DeviceSettingsSection(model: model)
        }
        .navigationTitle("Manage pendant")
    }
}
