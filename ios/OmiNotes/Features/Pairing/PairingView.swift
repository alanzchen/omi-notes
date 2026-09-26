import OmiBLE
import SwiftUI

/// Foreground scan for nearby Omi devices (service UUID or known names; OmiGlass excluded).
struct PairingView: View {
    let model: AppModel
    var onPaired: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let s = model.snapshot
        List {
            Section {
                if s.bluetooth != .poweredOn && !s.simulated {
                    Label(bluetoothHint(s.bluetooth), systemImage: "antenna.radiowaves.left.and.right.slash").foregroundStyle(.orange)
                }
                if s.scanResults.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Looking for Omi devices…").foregroundStyle(.secondary).padding(.leading, 6)
                    }
                }
                ForEach(s.scanResults) { c in
                    Button {
                        model.engine.pair(id: c.id, name: c.name)
                        onPaired?()
                        if onPaired == nil { dismiss() }
                    } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            VStack(alignment: .leading) {
                                Text(c.name).foregroundStyle(.primary)
                                Text(c.id.uuidString.prefix(8)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(c.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                            if c.id.uuidString.lowercased() == s.rememberedDeviceId { Image(systemName: "checkmark") }
                        }
                    }
                }
            } footer: {
                Text("Only one phone app can be connected to the pendant. Disconnect or quit the official Omi app first. In the Simulator, turn on the simulated device in the Debug tab.")
            }
        }
        .navigationTitle("Pair device")
        .onAppear { model.engine.startScan() }
        .onDisappear { model.engine.stopScan() }
    }

    private func bluetoothHint(_ s: CentralState) -> String {
        switch s {
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission denied — enable it in Settings › Omi Notes"
        case .unsupported: return "Bluetooth LE is unavailable here (Simulator?)"
        default: return "Bluetooth is starting…"
        }
    }
}
