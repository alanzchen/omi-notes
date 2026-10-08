import OmiBLE
import OmiCapture
import SwiftUI

/// Everything about the pendant in one place: is it connected and recording, is audio reaching the
/// server, and the pendant actions. It only shows the engine's existing state; retrying uploads and
/// the connection actions are the same ones Settings and Diagnostics offer.
struct PendantView: View {
    let model: AppModel
    var onFix: (SystemHealth.Fix) -> Void

    private var s: EngineSnapshot { model.snapshot }

    var body: some View {
        List {
            Section {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let steps = model.health(now: context.date).steps.filter { $0.area == .pendant || $0.area == .phone }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(steps) { step in StepRow(step: step, onFix: onFix) }
                    }
                    .padding(.vertical, 4)
                }
                if s.simulated { Label("Simulated pendant", systemImage: "testtube.2").foregroundStyle(.orange) }
            } header: {
                Text("Now")
            }
            DeviceSettingsSection(model: model)
            PendantDeviceSection(snapshot: s)
            LiveRecordingSection(snapshot: s)
            PendantSyncSection(snapshot: s)
            UploadsSection(model: model)
        }
        .navigationTitle("Pendant")
    }
}
