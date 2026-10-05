#if canImport(SwiftUI)
import SwiftUI
import VendorContainment

/// The console: three wrapped vendor SDKs, the app's own kill switch for each,
/// and a launch timeline that shows a poisoned vendor being detected,
/// quarantined, and released.
public struct ContainmentConsoleView: View {
    @Bindable private var model: ContainmentConsoleModel

    public init(model: ContainmentConsoleModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            List {
                controlsSection
                vendorsSection
                policySection
                timelineSection
            }
            .navigationTitle("SDK Containment")
        }
    }

    private var controlsSection: some View {
        Section {
            HStack {
                Button("Launch app") { Task { await model.launch() } }
                    .buttonStyle(.borderedProminent)
                Button("Replay ×4") { Task { await model.replayIncident() } }
                    .buttonStyle(.bordered)
                Button("Send event") { Task { await model.trackEvent() } }
                    .buttonStyle(.bordered)
            }
            .disabled(model.isBusy)
            if let message = model.lastMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Cold launches")
        } footer: {
            Text("Each launch is a fresh process. Only the containment store survives a crash, exactly as on a device.")
        }
    }

    private var vendorsSection: some View {
        Section("Wrapped vendor SDKs") {
            ForEach(model.vendorRows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: row.isHealthy ? "checkmark.shield" : "exclamationmark.shield")
                            .foregroundStyle(row.isHealthy ? .green : .orange)
                        Text(row.id.rawValue).font(.headline)
                        Spacer()
                        Text(row.stage == .afterFirstFrame ? "after 1st frame" : "idle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(row.state).font(.subheadline)
                    Text("strikes \(row.strikes) · buffered \(row.buffered) · sent \(row.sent) · dropped \(row.dropped)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Picker("Fault", selection: Binding(
                        get: { model.faults[row.id] ?? SimulatedFault.none },
                        set: { model.setFault($0, for: row.id) }
                    )) {
                        Text("Healthy").tag(SimulatedFault.none)
                        Text("Null flag → crash on start").tag(SimulatedFault.nullFlagCrashOnStart)
                        Text("Crash after start").tag(SimulatedFault.crashAfterStart)
                        Text("Crash when another SDK starts").tag(SimulatedFault.crashWhenAnotherStartsDuringProbation)
                    }
                    .pickerStyle(.menu)
                    HStack {
                        Toggle("App kill switch", isOn: Binding(
                            get: { model.killed.contains(row.id) },
                            set: { _ in model.toggleKillSwitch(row.id) }
                        ))
                        if row.quarantined {
                            Button("Release") { model.releaseQuarantine(row.id) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .font(.caption)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var policySection: some View {
        Section {
            Toggle("Validate vendor payloads before start", isOn: $model.validatesPayloads)
            LabeledContent("Policy", value: model.policySummary)
            LabeledContent("Next policy version", value: "v\(model.policyVersion)")
            HStack {
                LabeledContent("App build", value: model.appVersion)
                Button("Ship new build") { model.upgradeApp() }.buttonStyle(.bordered)
            }
        } header: {
            Text("App-owned control plane")
        } footer: {
            Text("Validation stops a poisoned payload on the first launch. With it off, the crash sentinel contains the vendor after \(model.strikeThreshold) attributed crashes.")
        }
    }

    private var timelineSection: some View {
        Section("Launch timeline") {
            if model.launches.isEmpty {
                Text("No launches yet. Tap Launch app, or Replay ×4.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.launches) { launch in
                VStack(alignment: .leading, spacing: 4) {
                    Label("Launch \(launch.id): \(launch.headline)",
                          systemImage: launch.crashedBy == nil ? "checkmark.circle" : "xmark.octagon")
                        .foregroundStyle(launch.crashedBy == nil ? Color.primary : Color.red)
                    ForEach(Array(launch.details.enumerated()), id: \.offset) { _, line in
                        Text("• \(line)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
#endif
