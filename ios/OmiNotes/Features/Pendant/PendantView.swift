import OmiBLE
import OmiCapture
import SwiftUI

/// The pendant at a glance: connected or not, battery, the one thing to do (if any), where audio is
/// between the pendant, this phone and the server, and the server's activity across all recordings.
/// Details, pendant actions and diagnostics are one level down. Everything comes from
/// `PendantSummary`, which only states what the app has observed.
struct PendantView: View {
    let model: AppModel
    var onFix: (SystemHealth.Fix) -> Void

    /// Simulator screenshots only (debug builds): `-OmiNotesDebugPendantState normal|disconnected|unpaired|blocked`
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
            List {
                Section {
                    PendantHeader(summary: p)
                    HeroRow(step: p.headline, onFix: onFix)
                    ForEach(p.also) { step in HeroRow(step: step, onFix: onFix, compact: true) }
                    if p.headline.area == .pendant, p.connectionTitle == "Not connected" { WhyNotConnected() }
                    #if DEBUG
                    if synthetic {
                        Label("Synthetic preview (debug build)", systemImage: "testtube.2").font(.footnote).foregroundStyle(.orange)
                    }
                    #endif
                    if !synthetic, model.snapshot.simulated {
                        Label("Simulated pendant", systemImage: "testtube.2").font(.footnote).foregroundStyle(.orange)
                    }
                }
                if let c = p.collecting {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Collecting audio saved on the pendant").font(.subheadline.weight(.semibold))
                            Text("\(c.received) of \(c.total) records · keep the phone nearby").font(.footnote).foregroundStyle(.secondary)
                            ProgressView(value: Double(c.received), total: Double(max(c.total, 1)))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section {
                    FlowView(flow: p.flow)
                } header: {
                    Text("From pendant to server")
                }
                if let notes = p.notes {
                    Section {
                        NotesRow(notes: notes, now: context.date)
                    } header: {
                        Text("On your server · all recordings")
                    } footer: {
                        Text("Counts every recording your server has, not only what this pendant just sent.")
                    }
                }
                Section {
                    Label("Tap once to bookmark a moment; double-tap to end the conversation.", systemImage: "hand.tap")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink { ManagePendantView(model: model) } label: { Label("Manage pendant", systemImage: "slider.horizontal.3") }
                    NavigationLink { DiagnosticsView(model: model) } label: { Label("Troubleshooting details", systemImage: "stethoscope") }
                }
            }
        }
        .navigationTitle("Pendant")
    }
}

/// Connection on the left, battery on the right; stacked at accessibility text sizes.
private struct PendantHeader: View {
    let summary: PendantSummary
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        AdaptiveStack(vertical: typeSize.isAccessibilitySize, spacing: 8) {
            Label(summary.connectionTitle, systemImage: summary.connected ? "dot.radiowaves.left.and.right" : "circle.dashed")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(summary.connected ? Color.primary : Color.secondary)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            BatteryChip(battery: summary.battery)
        }
    }
}

struct BatteryChip: View {
    let battery: PendantSummary.Battery

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(text).monospacedDigit()
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.12), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var symbol: String {
        switch battery {
        case .unknown: return "battery.0percent"
        case .level(_, true, _): return "battery.100percent.bolt"
        case .level(_, _, true): return "exclamationmark.triangle.fill"
        case .level(let p, _, _):
            return p >= 88 ? "battery.100percent" : p >= 63 ? "battery.75percent" : p >= 38 ? "battery.50percent" : "battery.25percent"
        }
    }

    private var text: String {
        switch battery {
        case .unknown: return "Battery —"
        case .level(let p, true, _): return "\(p)% charging"
        case .level(let p, _, true): return "Low \(p)%"
        case .level(let p, _, _): return "\(p)%"
        }
    }

    private var color: Color {
        switch battery {
        case .unknown: return .secondary
        case .level(_, _, true): return .orange
        case .level: return .primary
        }
    }

    private var label: String {
        switch battery {
        case .unknown(let reason): return "Pendant battery unknown. \(reason)."
        case .level(let p, true, _): return "Pendant battery \(p) percent, charging."
        case .level(let p, _, true): return "Pendant battery low, \(p) percent. Charge it soon."
        case .level(let p, _, _): return "Pendant battery \(p) percent."
        }
    }
}

/// The one-sentence situation and, when there is one, the action that fixes it.
private struct HeroRow: View {
    let step: SystemHealth.Step
    var onFix: (SystemHealth.Fix) -> Void
    var compact = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AdaptiveStack(vertical: typeSize.isAccessibilitySize, spacing: 10) {
                Image(systemName: step.level.symbol).font(compact ? .body : .title2).foregroundStyle(step.level.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title).font(compact ? .subheadline.weight(.semibold) : .headline)
                    if let detail = step.detail { Text(detail).font(compact ? .footnote : .subheadline).foregroundStyle(.secondary) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(step.level.accessibilityName). \(step.title). \(step.detail ?? "")")
            if let fix = step.fix, step.level >= .delayed {
                if compact {
                    Button(fix.title) { onFix(fix) }.buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button { onFix(fix) } label: { Text(fix.title).frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, compact ? 2 : 4)
    }
}

/// Shown while a paired pendant isn't connected; the app keeps reconnecting on its own.
private struct WhyNotConnected: View {
    var body: some View {
        DisclosureGroup("Why might this happen?") {
            VStack(alignment: .leading, spacing: 6) {
                Label("It's switched off, out of charge or out of range.", systemImage: "battery.0percent")
                Label("The official Omi app is connected: only one app can connect at a time.", systemImage: "iphone.slash")
                Label("Omi Notes was force-quit. Leave it running in the background.", systemImage: "moon.zzz")
            }
            .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 4)
        }
        .font(.subheadline)
    }
}

/// Pendant → phone → server, each with what was last observed; a column list at large text sizes.
private struct FlowView: View {
    let flow: [PendantSummary.Flow]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        AdaptiveStack(vertical: typeSize.isAccessibilitySize, spacing: 12) {
            ForEach(flow) { item in
                AdaptiveStack(vertical: !typeSize.isAccessibilitySize, spacing: 4) {
                    Image(systemName: item.level.symbol).font(.title3).foregroundStyle(item.level.color).accessibilityHidden(true)
                    VStack(alignment: typeSize.isAccessibilitySize ? .leading : .center, spacing: 2) {
                        Text(item.place.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(item.title).font(.footnote.weight(.semibold))
                        if let detail = item.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                    }
                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .center)
                }
                .frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity, alignment: .top)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.place.title): \(item.level.accessibilityName). \(item.title). \(item.detail ?? "")")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Server-wide figures, with their age when they are not current.
private struct NotesRow: View {
    let notes: PendantSummary.Notes
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let n = notes.processing {
                Text(n == 0 ? "Nothing being processed right now" : "\(n) conversation\(n == 1 ? "" : "s") being processed")
            }
            Text(notes.lastNoteAt.map { "Last note \(SystemHealth.relative($0, now))" } ?? "No notes yet")
                .foregroundStyle(.secondary)
            if notes.stale {
                Label("As of \(Fmt.time(notes.asOf)); the server hasn't answered since.", systemImage: "clock.badge.questionmark")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
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

extension PendantSummary.Flow.Place {
    var title: String {
        switch self {
        case .pendant: return "Pendant"
        case .phone: return "Phone"
        case .server: return "Server"
        }
    }
}
