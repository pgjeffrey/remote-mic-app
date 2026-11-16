import AppKit
import SwiftUI

struct KeyboardFnSettingsView: View {
    @ObservedObject var controller: KeyboardFnController
    @EnvironmentObject private var localization: LocalizationStore
    @State private var selectedID: String?
    @State private var draftName = ""
    @State private var draftSource = KeyboardFnKey.rightControl

    private var selected: KeyboardFnRow? { controller.rows.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("keyboard_fn.title").font(.system(size: 24, weight: .bold))
                    Text("keyboard_fn.subtitle")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button("keyboard_fn.disable_all") { controller.disableAll() }
                    .disabled(!controller.rows.contains { $0.enabled || $0.status == .enabled || $0.status == .waiting })
            }
            if !controller.permissionGranted {
                HStack(spacing: 12) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text("keyboard_fn.permission").fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("permission.action.open_settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    }
                }
                .padding(14)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if let issue = controller.issue {
                Label(LocalizedStringKey(issue.messageKey), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 24) {
                keyboardList.frame(width: 216)
                Divider()
                ScrollView {
                    if let row = selected { editor(row).frame(maxWidth: .infinity, alignment: .leading) }
                    else {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "keyboard").font(.system(size: 32)).foregroundStyle(.secondary)
                            Text("keyboard_fn.empty.title").font(.system(size: 17, weight: .semibold))
                            Text("keyboard_fn.empty.detail").foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("keyboard_fn.refresh") { controller.refresh() }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 28)
                    }
                }
            }
        }
        .font(.system(size: 13))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: controller.rows.map(\.id)) { _, _ in selectFirstIfNeeded() }
        .onChange(of: controller.capturedKey) { _, key in
            if let key { draftSource = key }
        }
        .onDisappear { controller.cancelCapture(reason: "left_keyboard_page") }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            controller.cancelCapture(reason: "window_inactive")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            controller.cancelCapture(reason: "app_hidden")
        }
    }

    private var keyboardList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("keyboard_fn.devices").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { controller.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help(Text("keyboard_fn.refresh"))
                    .accessibilityLabel(Text("keyboard_fn.refresh"))
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(controller.rows) { row in
                        Button { select(row) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: "keyboard").accessibilityHidden(true)
                                    Text(verbatim: displayName(row)).fontWeight(.semibold)
                                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Text(LocalizedStringKey(row.status.messageKey))
                                    .foregroundStyle(row.status == .enabled ? Color.accentColor : Color.secondary)
                                    .lineLimit(2)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedID == row.id ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(selectedID == row.id ? Color.accentColor : Color.clear, lineWidth: 1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedID == row.id ? .isSelected : [])
                    }
                }
            }
            Text("keyboard_fn.devices.help").font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func editor(_ row: KeyboardFnRow) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: displayName(row)).font(.system(size: 19, weight: .semibold))
                Text(LocalizedStringKey(row.status.messageKey)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("keyboard_fn.nickname").fontWeight(.semibold)
                TextField("keyboard_fn.nickname.placeholder", text: $draftName)
                    .textFieldStyle(.roundedBorder).disabled(controller.captureRowID != nil)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("keyboard_fn.mapping").fontWeight(.semibold)
                HStack(spacing: 14) {
                    keyCap(keyLabel(draftSource))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    keyCap(localization.text("keyboard_fn.function"))
                }
                Text("keyboard_fn.mapping.help").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("keyboard_fn.record") { controller.beginRecording(rowID: row.id) }
                    .disabled(row.device == nil || controller.captureRowID != nil || !controller.permissionGranted)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Button("keyboard_fn.identify") { controller.identify(rowID: row.id) }
                    .disabled(controller.captureRowID != nil || !controller.permissionGranted)
                Text("keyboard_fn.identify.help").font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = controller.captureMessageKey {
                VStack(alignment: .leading, spacing: 10) {
                    Label(LocalizedStringKey(message), systemImage: controller.captureRowID == nil ? "info.circle" : "keyboard")
                        .fixedSize(horizontal: false, vertical: true)
                    if controller.captureRowID != nil {
                        Button("keyboard_fn.cancel") { controller.cancelCapture() }
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 12) {
                Button("keyboard_fn.save_enable") {
                    controller.save(rowID: row.id, name: draftName, source: draftSource)
                    // A newly saved device now has a durable profile ID.
                    if let device = row.device,
                       let saved = controller.rows.first(where: { $0.profile != nil && $0.device?.serviceID == device.serviceID }) {
                        selectedID = saved.id
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.captureRowID != nil || !controller.permissionGranted)
                Button("keyboard_fn.cancel") { controller.cancelCapture(); loadDraft(row) }
                    .disabled(controller.captureRowID != nil)
            }
            if row.profile != nil {
                Button("keyboard_fn.disable") { controller.disable(rowID: row.id) }
                    .disabled(controller.captureRowID != nil)
            }
            Text("keyboard_fn.footer").font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 20)
    }

    private func keyCap(_ title: String) -> some View {
        Text(verbatim: title).font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)) }
    }

    private func keyLabel(_ key: KeyboardFnKey) -> String {
        if (0xE0...0xE7).contains(key.usage) { return localization.text("keyboard_fn.key.\(key.usage)") }
        return key.label
    }

    private func displayName(_ row: KeyboardFnRow) -> String {
        row.name.isEmpty ? localization.text("keyboard_fn.unnamed") : row.name
    }

    private func select(_ row: KeyboardFnRow) {
        controller.cancelCapture(reason: "selection_changed")
        selectedID = row.id
        loadDraft(row)
    }

    private func loadDraft(_ row: KeyboardFnRow) {
        draftName = row.name
        draftSource = row.source
    }

    private func selectFirstIfNeeded() {
        guard selected == nil, let first = controller.rows.first else { return }
        selectedID = first.id
        loadDraft(first)
    }
}
