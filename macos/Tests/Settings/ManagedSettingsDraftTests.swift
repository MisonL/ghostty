import Testing
@testable import Ghostty

struct ManagedSettingsDraftTests {
    @Test func managedBlockContentsIncludesExpandedSettings() {
        let draft = ManagedSettingsDraft(
            focusFollowsMouse: true,
            windowStepResize: true,
            windowShadow: false,
            autoSecureInput: true,
            secureInputIndication: false,
            scrollbar: .never,
            windowSaveState: "always",
            backgroundOpacity: 0.65,
            quickTerminalPosition: .center,
            quickTerminalScreen: .menuBar,
            quickTerminalAutoHide: false,
            quickTerminalSpaceBehavior: .remain,
            quickTerminalAnimationDuration: 0.35,
            resizeOverlay: .always,
            resizeOverlayPosition: .bottom_right,
            resizeOverlayDurationMilliseconds: 1450,
            notifyOnCommandFinish: .always,
            notifyActionBell: false,
            notifyActionNotify: true,
            notifyOnCommandFinishAfterSeconds: 12,
            macosShortcuts: .allow,
            autoUpdateChannel: .tip
        )

        let block = draft.managedBlockContents()
        #expect(block.contains("quick-terminal-animation-duration = 0.35s"))
        #expect(block.contains("resize-overlay = always"))
        #expect(block.contains("resize-overlay-position = bottom-right"))
        #expect(block.contains("resize-overlay-duration = 1450ms"))
        #expect(block.contains("notify-on-command-finish = always"))
        #expect(block.contains("notify-on-command-finish-action = no-bell,notify"))
        #expect(block.contains("notify-on-command-finish-after = 12s"))
        #expect(block.contains("macos-shortcuts = allow"))
        #expect(block.contains("quick-terminal-screen = macos-menu-bar"))
        #expect(block.contains("auto-update-channel = tip"))
    }

    @Test func replacingManagedBlockAppendsWhenMissing() {
        let original = "font-size = 14"
        let updated = ManagedSettingsFile.replacingManagedBlock(in: original, with: "managed = true")
        #expect(updated == "font-size = 14\n\nmanaged = true\n")
    }

    @Test func replacingManagedBlockReplacesExistingSectionAndPreservesNeighbors() {
        let original = """
        theme = dark

        # BEGIN Ghostty macOS Settings (managed)
        old = value
        # END Ghostty macOS Settings (managed)

        font-size = 14
        """

        let updated = ManagedSettingsFile.replacingManagedBlock(
            in: original,
            with: """
            # BEGIN Ghostty macOS Settings (managed)
            new = value
            # END Ghostty macOS Settings (managed)
            """
        )

        #expect(updated == """
        theme = dark

        # BEGIN Ghostty macOS Settings (managed)
        new = value
        # END Ghostty macOS Settings (managed)

        font-size = 14
        """)
    }

    @Test func replacingManagedBlockRemovesExistingSection() {
        let original = """
        a = 1

        # BEGIN Ghostty macOS Settings (managed)
        managed = true
        # END Ghostty macOS Settings (managed)

        b = 2
        """

        let updated = ManagedSettingsFile.replacingManagedBlock(in: original, with: nil)
        #expect(updated == "a = 1\n\nb = 2\n")
    }
}
