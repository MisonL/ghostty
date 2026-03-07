import AppKit
import SwiftUI
import GhosttyKit

@MainActor
final class SettingsModel: ObservableObject {
    private static let managedBlockStart = "# BEGIN Ghostty macOS Settings (managed)"
    private static let managedBlockEnd = "# END Ghostty macOS Settings (managed)"

    @Published private(set) var config: Ghostty.Config
    @Published private(set) var configPath: String
    @Published var managedFocusFollowsMouse: Bool = false
    @Published var managedWindowStepResize: Bool = false
    @Published var managedWindowShadow: Bool = false
    @Published var managedAutoSecureInput: Bool = false
    @Published var managedSecureInputIndication: Bool = false
    @Published var managedScrollbar: Ghostty.Config.Scrollbar = .system
    @Published private(set) var hasManagedOverrides: Bool = false
    @Published private(set) var saveMessage: String?
    @Published private(set) var saveMessageIsError: Bool = false

    private var configObserver: NSObjectProtocol?

    init(config: Ghostty.Config? = nil) {
        self.config = config ?? Ghostty.Config()
        self.configPath = Self.resolveConfigPath()
        self.refreshDraftFromConfig()

        configObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                guard notification.object == nil else { return }

                if let updated = notification.userInfo?[Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config {
                    self.config = updated
                } else {
                    self.refresh()
                }

                self.configPath = Self.resolveConfigPath()
                self.refreshDraftFromConfig()
            }
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    var diagnosticsCount: Int { config.errors.count }

    func refresh() {
        if let appDelegate = NSApp.delegate as? AppDelegate,
           let cfg = appDelegate.ghostty.config.config
        {
            config = Ghostty.Config(clone: cfg)
        }
        configPath = Self.resolveConfigPath()
        refreshDraftFromConfig()
    }

    func openConfig() {
        Ghostty.App.openConfig()
    }

    func reloadConfig() {
        (NSApp.delegate as? AppDelegate)?.reloadConfig(nil)
    }

    func showConfigurationErrors() {
        let controller = ConfigurationErrorsController.sharedInstance
        controller.errors = config.errors
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func saveManagedSettings() {
        do {
            let path = try ensureConfigPath()
            let contents = try readConfigFile(at: path)
            let updated = Self.replacingManagedBlock(
                in: contents,
                with: managedBlockContents(),
            )
            try writeConfigFile(updated, to: path)

            hasManagedOverrides = true
            saveMessage = "Saved managed settings to the config file and requested a reload."
            saveMessageIsError = false
            reloadConfig()
        } catch {
            saveMessage = "Failed to save managed settings: \(error.localizedDescription)"
            saveMessageIsError = true
        }
    }

    func removeManagedSettings() {
        do {
            let path = try ensureConfigPath()
            let contents = try readConfigFile(at: path)
            let updated = Self.replacingManagedBlock(in: contents, with: nil)
            try writeConfigFile(updated, to: path)

            hasManagedOverrides = false
            saveMessage = "Removed the managed settings block and requested a reload."
            saveMessageIsError = false
            reloadConfig()
        } catch {
            saveMessage = "Failed to remove managed settings: \(error.localizedDescription)"
            saveMessageIsError = true
        }
    }

    private static func resolveConfigPath() -> String {
        Ghostty.AllocatedString(ghostty_config_open_path()).string
    }

    private func refreshDraftFromConfig() {
        managedFocusFollowsMouse = config.focusFollowsMouse
        managedWindowStepResize = config.windowStepResize
        managedWindowShadow = config.macosWindowShadow
        managedAutoSecureInput = config.autoSecureInput
        managedSecureInputIndication = config.secureInputIndication
        managedScrollbar = config.scrollbar
        hasManagedOverrides = Self.hasManagedBlock(in: configPath)
    }

    private func managedBlockContents() -> String {
        [
            Self.managedBlockStart,
            "# This block is written by Ghostty's macOS settings window.",
            "# It overrides earlier definitions of the same keys.",
            "focus-follows-mouse = \(managedFocusFollowsMouse)",
            "window-step-resize = \(managedWindowStepResize)",
            "macos-window-shadow = \(managedWindowShadow)",
            "macos-auto-secure-input = \(managedAutoSecureInput)",
            "macos-secure-input-indication = \(managedSecureInputIndication)",
            "scrollbar = \(managedScrollbar.rawValue)",
            Self.managedBlockEnd,
        ].joined(separator: "\n")
    }

    private func ensureConfigPath() throws -> String {
        let path = configPath.isEmpty ? Self.resolveConfigPath() : configPath
        guard !path.isEmpty else {
            throw SettingsPersistenceError.missingConfigPath
        }

        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data())
        }

        configPath = path
        return path
    }

    private func readConfigFile(at path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func writeConfigFile(_ contents: String, to path: String) throws {
        try contents.write(
            to: URL(fileURLWithPath: path),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func hasManagedBlock(in path: String) -> Bool {
        guard !path.isEmpty,
              let contents = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        else { return false }
        return contents.contains(managedBlockStart) && contents.contains(managedBlockEnd)
    }

    private static func replacingManagedBlock(in contents: String, with block: String?) -> String {
        guard let start = contents.range(of: managedBlockStart),
              let end = contents.range(of: managedBlockEnd, range: start.lowerBound..<contents.endIndex)
        else {
            guard let block else { return contents }
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "\(block)\n" : "\(trimmed)\n\n\(block)\n"
        }

        let before = contents[..<start.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let after = contents[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let middle = block?.trimmingCharacters(in: .whitespacesAndNewlines)

        var sections: [String] = []
        if !before.isEmpty { sections.append(String(before)) }
        if let middle, !middle.isEmpty { sections.append(middle) }
        if !after.isEmpty { sections.append(String(after)) }
        return sections.joined(separator: "\n\n") + (sections.isEmpty ? "" : "\n")
    }
}

private enum SettingsPersistenceError: LocalizedError {
    case missingConfigPath

    var errorDescription: String? {
        switch self {
        case .missingConfigPath:
            return "Ghostty could not resolve a writable configuration path."
        }
    }
}

@MainActor
final class SettingsController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsController()

    private let model = SettingsModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model))

        super.init(window: window)
        shouldCascadeWindows = false
        self.window?.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for SettingsController")
    }

    func show() {
        model.refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func close(_ sender: Any?) {
        window?.performClose(sender)
    }

    @objc func cancel(_ sender: Any?) {
        close(sender)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                managedSettings

                if model.diagnosticsCount > 0 {
                    diagnosticsBanner
                }

                SettingsSection("General") {
                    SettingsRow("Config File", value: model.configPath.isEmpty ? "No config file resolved" : model.configPath, monospace: true)
                    SettingsRow("Initial Window", value: describe(model.config.initialWindow))
                    SettingsRow("Quit After Last Window", value: describe(model.config.shouldQuitAfterLastWindowClosed))
                    SettingsRow("Focus Follows Mouse", value: describe(model.config.focusFollowsMouse))
                    SettingsRow("Scrollbar", value: model.config.scrollbar.rawValue)
                    SettingsRow("Commands in Palette", value: "\(model.config.commandPaletteEntries.count)")
                }

                SettingsSection("Windowing") {
                    SettingsRow("Window Title", value: valueOrDefault(model.config.title))
                    SettingsRow("Window Save State", value: model.config.windowSaveState)
                    SettingsRow("New Tab Position", value: model.config.windowNewTabPosition)
                    SettingsRow("Window Theme", value: valueOrDefault(model.config.windowTheme))
                    SettingsRow("Decorations", value: describe(model.config.windowDecorations))
                    SettingsRow("Step Resize", value: describe(model.config.windowStepResize))
                    SettingsRow("Fullscreen Mode", value: describe(model.config.windowFullscreen))
                    SettingsRow("Titlebar Style", value: model.config.macosTitlebarStyle)
                    SettingsRow("Titlebar Proxy Icon", value: model.config.macosTitlebarProxyIcon.rawValue)
                    SettingsRow("Window Buttons", value: model.config.macosWindowButtons.rawValue)
                    SettingsRow("Window Shadow", value: describe(model.config.macosWindowShadow))
                    SettingsRow("Title Font Family", value: valueOrDefault(model.config.windowTitleFontFamily))
                }

                SettingsSection("Appearance") {
                    SettingsRow("Background Opacity", value: String(format: "%.2f", model.config.backgroundOpacity))
                    SettingsRow("Background Blur", value: describe(model.config.backgroundBlur))
                    SettingsRow("App Icon", value: model.config.macosIcon.rawValue)
                    SettingsRow("App Icon Frame", value: model.config.macosIconFrame.rawValue)
                    SettingsRow("Dock Drop Behavior", value: model.config.macosDockDropBehavior.rawValue)
                    SettingsRow("Hidden Behavior", value: model.config.macosHidden.rawValue)
                    SettingsRow("Auto Secure Input", value: describe(model.config.autoSecureInput))
                    SettingsRow("Secure Input Indicator", value: describe(model.config.secureInputIndication))
                    SettingsRow("macOS Shortcuts", value: model.config.macosShortcuts.rawValue)
                    BackgroundSwatchRow(color: model.config.backgroundColor)
                }

                SettingsSection("Quick Terminal") {
                    SettingsRow("Position", value: model.config.quickTerminalPosition.rawValue)
                    SettingsRow("Screen", value: describe(model.config.quickTerminalScreen))
                    SettingsRow("Auto Hide", value: describe(model.config.quickTerminalAutoHide))
                    SettingsRow("Animation Duration", value: String(format: "%.2f s", model.config.quickTerminalAnimationDuration))
                    SettingsRow("Space Behavior", value: describe(model.config.quickTerminalSpaceBehavior))
                    SettingsRow("Size", value: describe(model.config.quickTerminalSize))
                    SettingsRow("Resize Overlay", value: model.config.resizeOverlay.rawValue)
                    SettingsRow("Resize Overlay Position", value: model.config.resizeOverlayPosition.rawValue)
                    SettingsRow("Resize Overlay Duration", value: "\(model.config.resizeOverlayDuration) ms")
                }

                SettingsSection("Notifications and Updates") {
                    SettingsRow("Notify on Command Finish", value: model.config.notifyOnCommandFinish.rawValue)
                    SettingsRow("Notify Action", value: describe(model.config.notifyOnCommandFinishAction))
                    SettingsRow("Notify After", value: String(describing: model.config.notifyOnCommandFinishAfter))
                    SettingsRow("Auto Update", value: model.config.autoUpdate?.rawValue ?? "disabled")
                    SettingsRow("Update Channel", value: model.config.autoUpdateChannel.rawValue)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 720, minHeight: 640)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                Image("AppIconImage")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings")
                        .font(.title)

                    Text("This first version surfaces the active Ghostty configuration and common maintenance actions. Advanced changes still belong in the config file.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button("Open Config File") { model.openConfig() }
                    .buttonStyle(.borderedProminent)
                Button("Reload Configuration") { model.reloadConfig() }
                if model.diagnosticsCount > 0 {
                    Button("Show Configuration Errors") { model.showConfigurationErrors() }
                }
                Spacer()
                Text("Diagnostics: \(model.diagnosticsCount)")
                    .foregroundStyle(model.diagnosticsCount > 0 ? .orange : .secondary)
            }
        }
    }

    private var managedSettings: some View {
        SettingsSection("Managed Settings") {
            Text("Save a small set of common macOS preferences into a managed block at the end of your config file. These values override earlier definitions of the same keys, and Ghostty reloads after saving.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let saveMessage = model.saveMessage {
                Text(saveMessage)
                    .foregroundStyle(model.saveMessageIsError ? .red : .secondary)
            }

            Toggle("Focus Follows Mouse", isOn: $model.managedFocusFollowsMouse)
            Toggle("Window Step Resize", isOn: $model.managedWindowStepResize)
            Toggle("macOS Window Shadow", isOn: $model.managedWindowShadow)
            Toggle("Auto Secure Input", isOn: $model.managedAutoSecureInput)
            Toggle("Secure Input Indicator", isOn: $model.managedSecureInputIndication)

            HStack(spacing: 12) {
                Text("Scrollbar")
                    .foregroundStyle(.secondary)
                    .frame(width: 220, alignment: .leading)
                Picker("Scrollbar", selection: $model.managedScrollbar) {
                    Text("system").tag(Ghostty.Config.Scrollbar.system)
                    Text("never").tag(Ghostty.Config.Scrollbar.never)
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 10) {
                Button("Save and Reload") { model.saveManagedSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Remove Managed Overrides") { model.removeManagedSettings() }
                    .disabled(!model.hasManagedOverrides)
                Spacer()
            }
        }
    }

    private var diagnosticsBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Ghostty loaded the current configuration with \(model.diagnosticsCount) diagnostic(s). You can still inspect the active values below, then open the detailed diagnostics window if needed.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func valueOrDefault(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Default" }
        return value
    }

    private func describe(_ value: Bool) -> String {
        value ? "Enabled" : "Disabled"
    }

    private func describe(_ value: Ghostty.Config.NotifyOnCommandFinishAction) -> String {
        var components: [String] = []
        if value.contains(.bell) { components.append("bell") }
        if value.contains(.notify) { components.append("notify") }
        return components.isEmpty ? "none" : components.joined(separator: ", ")
    }

    private func describe(_ value: Ghostty.Config.BackgroundBlur) -> String {
        switch value {
        case .disabled:
            return "Disabled"
        case .radius(let radius):
            return "\(radius) px"
        case .macosGlassRegular:
            return "macOS glass (regular)"
        case .macosGlassClear:
            return "macOS glass (clear)"
        }
    }

    private func describe(_ value: FullscreenMode?) -> String {
        guard let value else { return "Disabled" }
        return value.rawValue
    }

    private func describe(_ value: QuickTerminalScreen) -> String {
        switch value {
        case .main:
            return "main"
        case .mouse:
            return "mouse"
        case .menuBar:
            return "menu-bar"
        }
    }

    private func describe(_ value: QuickTerminalSpaceBehavior) -> String {
        switch value {
        case .move:
            return "move"
        case .remain:
            return "remain"
        }
    }

    private func describe(_ value: QuickTerminalSize) -> String {
        "primary: \(describe(value.primary)), secondary: \(describe(value.secondary))"
    }

    private func describe(_ value: QuickTerminalSize.Size?) -> String {
        guard let value else { return "default" }
        switch value {
        case .percentage(let percentage):
            return String(format: "%.0f%%", percentage)
        case .pixels(let pixels):
            return "\(pixels) px"
        }
    }
}

private struct SettingsSection<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(.headline)
        }
    }
}

private struct SettingsRow: View {
    private let label: String
    private let value: String
    private let monospace: Bool

    init(_ label: String, value: String, monospace: Bool = false) {
        self.label = label
        self.value = value
        self.monospace = monospace
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 220, alignment: .leading)

            Text(value)
                .font(monospace ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
    }
}

private struct BackgroundSwatchRow: View {
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Background Color")
                .foregroundStyle(.secondary)
                .frame(width: 220, alignment: .leading)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                )
                .frame(width: 44, height: 20)

            Spacer(minLength: 0)
        }
    }
}
