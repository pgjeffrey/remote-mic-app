import SwiftUI

struct MicrophoneMixerView: View {
    @ObservedObject var model: MicrophoneMixerModel
    @EnvironmentObject private var localization: LocalizationStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Text(localization.text("mixer.title"))
                    .font(.system(size: 24, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                Text(localization.text(model.stateKey))
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.7))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .accessibilityIdentifier("mixer.state")
                Spacer(minLength: 16)
                Toggle(localization.text("mixer.restore"), isOn: Binding(
                    get: { model.configuration.restoreOnLaunch }, set: model.setRestoreOnLaunch
                ))
                .toggleStyle(.switch)
                .font(.system(size: 13, weight: .medium))
                .fixedSize()
                Toggle(localization.text("mixer.start"), isOn: Binding(
                    get: { model.armed },
                    set: { enabled in
                        if enabled { model.start() } else { model.stop() }
                    }
                ))
                .toggleStyle(.switch)
                .font(.system(size: 13, weight: .medium))
                .fixedSize()
                .disabled((model.busy && model.stateKey == "mixer.state.stopping") || (!model.armed && !model.canStart))
                .accessibilityIdentifier("mixer.toggle")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Spacer()
                        Button { model.addInput() } label: {
                            Label(localization.text("mixer.add"), systemImage: "plus")
                        }
                        .disabled(model.armed || model.busy)
                        .accessibilityIdentifier("mixer.add")
                    }
                    if !model.available {
                        feedback("mixer.error.engine")
                    } else if model.output == nil {
                        feedback("mixer.error.output")
                    }
                    if let error = model.errorKey {
                        feedback(error)
                    }
                    if model.configuration.inputs.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "mic.badge.plus")
                                .font(.system(size: 30)).foregroundStyle(.primary.opacity(0.7))
                                .accessibilityHidden(true)
                            Text(localization.text("mixer.empty.title")).font(.system(size: 16, weight: .semibold))
                            Text(localization.text("mixer.empty.detail"))
                                .font(.system(size: 13)).foregroundStyle(.primary.opacity(0.7))
                                .multilineTextAlignment(.center)
                            Button(localization.text("mixer.add")) { model.addInput() }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, minHeight: 210)
                    } else {
                        VStack(spacing: 14) {
                            ForEach(0..<((model.configuration.inputs.count + 1) / 2), id: \.self) { row in
                                HStack(alignment: .top, spacing: 14) {
                                    ForEach(0..<2, id: \.self) { column in
                                        let index = row * 2 + column
                                        if index < model.configuration.inputs.count {
                                            let input = model.configuration.inputs[index]
                                            MicrophoneMixerInputCard(model: model, input: input)
                                                .id(input.id).frame(maxWidth: .infinity)
                                        } else {
                                            Color.clear.frame(maxWidth: .infinity)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localization.text("mixer.output"))
                        .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.7))
                    Text(model.output?.name ?? localization.text("mixer.output.none"))
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .help(model.output?.name ?? "")
                }
                MicrophoneMixerLevel(level: model.status.outputPeak, name: localization.text("mixer.level.output"))
                HStack(spacing: 12) {
                    Text(localization.text("mixer.master")).font(.system(size: 12))
                    Slider(value: Binding(get: { model.configuration.masterGain }, set: model.setMasterGain), in: 0...1.5)
                        .accessibilityLabel(localization.text("mixer.master"))
                    Text(model.configuration.masterGain, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 12)).monospacedDigit().frame(width: 42, alignment: .trailing)
                }
                Text(localization.text("mixer.close_help"))
                    .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
        .environment(\.locale, localization.locale)
    }

    private func feedback(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(localization.text(key), systemImage: "exclamationmark.triangle")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if key == "mixer.error.permission" {
                Button(localization.text("mixer.open_permissions")) {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct MicrophoneMixerInputCard: View {
    @ObservedObject var model: MicrophoneMixerModel
    let input: MicrophoneMixerInput
    @EnvironmentObject private var localization: LocalizationStore
    @State private var selecting = false

    private var device: AudioDeviceInfo? { model.devices.first { $0.uid == input.deviceUID } }
    private var status: MicrophoneMixerInputStatus? { model.status.inputs.first { $0.deviceUID == input.deviceUID } }
    private var name: String {
        device?.name ?? (input.name.isEmpty ? localization.text("mixer.select") : input.name)
    }
    private var state: String {
        if input.deviceUID.isEmpty { return "mixer.select" }
        if device == nil { return "mixer.input.missing" }
        if !model.armed { return "mixer.input.connected" }
        if !model.status.running { return "mixer.input.standby" }
        if status?.receiving != true { return "mixer.input.waiting" }
        return input.muted ? "mixer.input.muted" : "mixer.input.receiving"
    }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(localization.text(state), systemImage: device == nil ? "mic.slash" : "mic")
                        .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.7))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button { model.removeInput(input.id) } label: {
                        Image(systemName: "minus.circle").frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.armed || model.busy)
                    .accessibilityLabel(localization.text("mixer.remove"))
                }
                Group {
                    if model.armed {
                        Text(name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    } else {
                        Button { selecting = true } label: {
                            HStack(spacing: 6) {
                                Text(name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busy)
                        .accessibilityLabel(localization.text("mixer.select"))
                    }
                }
                .help(name)
                .popover(isPresented: $selecting) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(localization.text("mixer.select")).font(.system(size: 14, weight: .semibold))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(model.devices) { device in
                                    Button {
                                        model.selectInput(device.uid, id: input.id)
                                        selecting = false
                                    } label: {
                                        HStack {
                                            Text(device.name).font(.system(size: 13))
                                            Spacer()
                                            if device.uid == input.deviceUID { Image(systemName: "checkmark") }
                                        }
                                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(model.configuration.inputs.contains { $0.id != input.id && $0.deviceUID == device.uid })
                                }
                            }
                        }
                        .frame(maxHeight: 240)
                        Button(localization.text("common.action.cancel")) { selecting = false }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(16).frame(width: 330)
                }
                MicrophoneMixerLevel(level: status?.peak ?? 0, name: localization.text("mixer.level.input"))
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { input.gain }, set: { model.setGain($0, id: input.id) }), in: 0...1.5)
                        .accessibilityLabel(localization.text("mixer.volume.input"))
                    Text(input.gain, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 12)).monospacedDigit().frame(width: 38, alignment: .trailing)
                    Toggle(isOn: Binding(get: { input.muted }, set: { model.setMuted($0, id: input.id) })) {
                        Image(systemName: input.muted ? "mic.slash.fill" : "mic.fill")
                    }
                    .toggleStyle(.button)
                    .accessibilityLabel(localization.text("mixer.mute"))
                    .help(localization.text("mixer.mute"))
                }
            }
        }
    }
}

private struct MicrophoneMixerLevel: View {
    let level: Float
    let name: String

    private var fraction: Double {
        guard level.isFinite, level > 0 else { return 0 }
        return min(max((20 * log10(Double(level)) + 60) / 60, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(level >= 0.98 ? Color.orange : Color.green)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("\(Int(fraction * 100))%")
    }
}
