import AppKit
import SwiftUI
import GhosttyKit

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var config: Ghostty.Config
    @Published private(set) var configPath: String

    private var configObserver: NSObjectProtocol?

    init(config: Ghostty.Config? = nil) {
        self.config = config ?? Ghostty.Config()
        self.configPath = Self.resolveConfigPath()

        configObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard notification.object == nil else { return }

            if let updated = notification.userInfo?[Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config {
                self.config = updated
            } else {
                self.refresh()
            }

            self.configPath = Self.resolveConfigPath()
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

    private static func resolveConfigPath() -> String {
        Ghostty.AllocatedString(ghostty_config_open_path()).string
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
