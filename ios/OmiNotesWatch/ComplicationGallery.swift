#if DEBUG
import OmiWatchKit
import SwiftUI
import WidgetKit

/// Simulator previews only (`OmiWatchDebugComplicationGallery face|states|tinted|compare`): the real
/// complication view drawn at its size on a 46 mm face (50 pt). "face" places it in a CONCEPT watch
/// face drawn here (not the system face); the others show its states. Example values, not live.
struct ComplicationGallery: View {
    let mode = UserDefaults.standard.string(forKey: "OmiWatchDebugComplicationGallery") ?? "face"
    static let size: CGFloat = 50

    static let states: [(String, ComplicationDisplay)] = [
        ("Recording", ComplicationDisplay(main: .recording, sync: .waiting(seconds: 12 * 60 + 20))),
        ("Paused", ComplicationDisplay(main: .paused, sync: .onIPhone)),
        ("Problem", ComplicationDisplay(main: .error, sync: .waiting(seconds: 40))),
        ("Idle", ComplicationDisplay(main: .idle, sync: .onIPhone)),
        ("Unknown", ComplicationDisplay(main: .unknown, sync: .unknown)),
        ("Not paired", ComplicationDisplay(main: .idle, sync: .notConnected)),
    ]

    var body: some View {
        switch mode {
        case "states": grid { ComplicationCircle(display: $0) }
        // SIMULATED: the system tints accented faces itself; desaturating and tinting the whole
        // render shows whether the states still differ by shape alone
        case "tinted": VStack(spacing: 2) {
            Text("SIMULATED TINT").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.white.opacity(0.35))
            grid { ComplicationCircle(display: $0).grayscale(1).colorMultiply(Color(red: 0.55, green: 0.85, blue: 1)) }
        }
        case "compare": compare
        default: ConceptFace()
        }
    }

    private func grid<V: View>(@ViewBuilder _ make: @escaping (ComplicationDisplay) -> V) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Self.states, id: \.0) { name, display in
                    VStack(spacing: 4) {
                        make(display).frame(width: Self.size, height: Self.size).clipShape(Circle())
                        Text(name).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var compare: some View {
        VStack(spacing: 10) {
            ForEach(["A", "B"], id: \.self) { which in
                HStack(spacing: 8) {
                    Text(which).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary).frame(width: 12)
                    ForEach(Self.states.prefix(3), id: \.0) { _, d in
                        Group {
                            if which == "A" { ComplicationCircleA(display: d) } else { ComplicationCircleB(display: d) }
                        }
                        .frame(width: Self.size, height: Self.size).clipShape(Circle())
                    }
                }
            }
        }
    }
}

/// A watch face drawn for the preview (CONCEPT): time, date and four circular slots, one of them the
/// real Omi Notes complication; the other slots are left empty rather than imitating other apps.
private struct ConceptFace: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Text("CONCEPT FACE").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.white.opacity(0.35))
                Spacer(minLength: 0)
                Text("THU 15").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Color(red: 1, green: 0.42, blue: 0.35))
                Text("10:09").font(.system(size: 64, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                Spacer(minLength: 6)
                HStack(spacing: 10) {
                    emptySlot
                    ComplicationCircle(display: ComplicationGallery.states[0].1)
                        .frame(width: ComplicationGallery.size, height: ComplicationGallery.size).clipShape(Circle())
                    emptySlot
                }
                .padding(.bottom, 6)
            }
        }
    }

    private var emptySlot: some View {
        Circle().fill(Color.white.opacity(0.08)).frame(width: ComplicationGallery.size, height: ComplicationGallery.size)
    }
}
#endif
