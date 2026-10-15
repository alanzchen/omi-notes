#if DEBUG
import OmiWatchKit
import SwiftUI

/// Simulator screenshots only (`OmiWatchDebugComplicationGallery`): the complication's circular
/// view at real accessoryCircular sizes in each state, plus the live one read back from the shared
/// keychain store the extension reads. Not the installed watch face.
struct ComplicationGallery: View {
    let examples: [(String, ComplicationDisplay)] = [
        ("Recording · 12 min waiting", ComplicationDisplay(main: .recording, sync: .waiting(seconds: 12 * 60 + 20))),
        ("Paused · on iPhone", ComplicationDisplay(main: .paused, sync: .onIPhone)),
        ("Idle · 40 s waiting", ComplicationDisplay(main: .idle, sync: .waiting(seconds: 40))),
        ("Recording · 19 h waiting", ComplicationDisplay(main: .recording, sync: .waiting(seconds: 19 * 3600 + 300))),
        ("Unknown", ComplicationDisplay(main: .unknown, sync: .unknown)),
        ("Error", ComplicationDisplay(main: .error, sync: .onIPhone)),
        ("No iPhone", ComplicationDisplay(main: .idle, sync: .notConnected)),
    ]
    let size = CGFloat(UserDefaults.standard.double(forKey: "OmiWatchDebugComplicationSize").nonZero ?? 47)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in content }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 6) {
                let live = ComplicationStore(accessGroup: ComplicationKind.accessGroup).load()
                tile("LIVE: \(live.map { "\($0.recorder.rawValue), \(WaitingAudio.text($0.waitingSeconds ?? 0)) waiting" } ?? "none")",
                     ComplicationDisplay.evaluate(live, now: Date()))
                Text("EXAMPLES").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(examples, id: \.0) { tile($0.0, $0.1) }
                }
            }
        }
    }

    private func tile(_ label: String, _ d: ComplicationDisplay) -> some View {
        VStack(spacing: 2) {
            ComplicationCircle(display: d).frame(width: size, height: size).clipShape(Circle())
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
        }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
#endif
