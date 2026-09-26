import OmiBLE
import OmiCapture
import SwiftUI

struct DebugView: View {
    let model: AppModel
    @State private var logFilter = ""

    var body: some View {
        let s = model.snapshot
        List {
            Section {
                Toggle("Simulated device", isOn: Binding(get: { s.simulated }, set: { model.engine.setSimulatedMode($0) }))
                if s.simulated {
                    Button("Single tap (bookmark)") { model.engine.simulateButton(code: 1) }
                    Button("Double tap (end conversation)") { model.engine.simulateButton(code: 2) }
                    Button("Walk out of range for 15 s") { model.engine.simulateOutOfRange(returnAfter: 15) }
                }
            } header: {
                Text("Device")
            } footer: {
                Text("The simulated device replays a recorded CV1 notification trace in real time and serves a fake offline backlog, so the whole pipeline runs in the Simulator.")
            }

            Section("Capture & upload") {
                Button("Force chunk rotation") { model.engine.forceRotate() }
                Button("Send heartbeat now") { model.engine.sendHeartbeatNow() }
                Button("Retry uploads now") { model.engine.retryUploads() }
                Button("Run retention now") { model.engine.runRetentionNow() }
                if !s.quarantined.isEmpty {
                    Button("Re-queue kept files (\(s.quarantined.count))") { model.engine.requeueQuarantined() }
                }
                LabeledContent("Free space", value: s.freeBytes.map(Fmt.bytes) ?? "?")
                LabeledContent("Recovered at launch", value: "\(s.recoveredCaptures)")
                if let b = s.lastButton { LabeledContent("Last button", value: b) }
            }

            if !s.quarantined.isEmpty {
                Section("Kept, not uploaded") {
                    ForEach(s.quarantined, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }

            Section {
                TextField("Filter", text: $logFilter).textInputAutocapitalization(.never).autocorrectionDisabled()
                ForEach(model.logs.filter { logFilter.isEmpty || $0.message.localizedCaseInsensitiveContains(logFilter) || $0.category == logFilter }) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(line.date.formatted(date: .omitted, time: .standard)) · \(line.category) · \(line.level.rawValue)")
                            .font(.caption2).foregroundStyle(color(line.level))
                        Text(line.message).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            } header: {
                HStack {
                    Text("Log (tokens redacted)")
                    Spacer()
                    Button("Refresh") { model.refreshLogs() }.font(.caption)
                }
            }
        }
        .navigationTitle("Debug")
        .onAppear { model.refreshLogs() }
    }

    private func color(_ l: LogLine.Level) -> Color {
        switch l {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        case .debug: return .gray
        }
    }
}
