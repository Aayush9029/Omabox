import AppKit
import CustomDump
import Testing
@testable import Omabox

@MainActor
struct CoreInputTests {
    @Test func reservesCommandKeysWithCapsLockAndUnrelatedDeviceFlags() throws {
        let palette = try keyEvent(characters: "K", modifiers: [.command, .control, .option, .capsLock, .numericPad], keyCode: 40)
        let settings = try keyEvent(characters: ",", modifiers: [.command, .function], keyCode: 43)
        let shifted = try keyEvent(characters: "K", modifiers: [.command, .control, .option, .shift], keyCode: 40)
        expectNoDifference(ReservedHostKeyboardCommand(event: palette), .palette)
        expectNoDifference(ReservedHostKeyboardCommand(event: settings), .settings)
        #expect(ReservedHostKeyboardCommand(event: shifted) == nil)
    }

    @Test func guestViewConsumesRegisteredHostShortcutsInBothResponderPaths() throws {
        let display = GuestDisplayView()
        var handledCommands: [ReservedHostKeyboardCommand] = []
        display.reservedShortcutHandler = { event in
            guard let command = ReservedHostKeyboardCommand(event: event) else { return false }
            handledCommands.append(command)
            return true
        }
        let palette = try keyEvent(characters: "K", modifiers: [.command, .control, .option, .capsLock], keyCode: 40)
        let settings = try keyEvent(characters: ",", modifiers: .command, keyCode: 43)
        let release = try keyEvent(characters: "\u{1b}", modifiers: [.control, .option], keyCode: 53)
        #expect(display.performKeyEquivalent(with: palette))
        #expect(display.performKeyEquivalent(with: settings))
        #expect(display.performKeyEquivalent(with: release))
        display.keyDown(with: palette)
        display.keyDown(with: settings)
        display.keyDown(with: release)
        expectNoDifference(handledCommands, [.palette, .settings, .releaseInput, .palette, .settings, .releaseInput])
    }

    @Test func ordinaryGuestKeysAreNotReservedByTheHost() throws {
        let plainK = try keyEvent(characters: "k", modifiers: [], keyCode: 40)
        let controlK = try keyEvent(characters: "k", modifiers: .control, keyCode: 40)
        let commandK = try keyEvent(characters: "k", modifiers: .command, keyCode: 40)
        let escape = try keyEvent(characters: "\u{1b}", modifiers: [], keyCode: 53)
        #expect(ReservedHostKeyboardCommand(event: plainK) == nil)
        #expect(ReservedHostKeyboardCommand(event: controlK) == nil)
        #expect(ReservedHostKeyboardCommand(event: commandK) == nil)
        #expect(ReservedHostKeyboardCommand(event: escape) == nil)
    }

    @Test func commandKPassesBothGuestResponderPathsWithoutOpeningHostPalette() throws {
        let display = GuestDisplayView()
        var handledCommands: [ReservedHostKeyboardCommand] = []
        display.reservedShortcutHandler = { event in
            guard let command = ReservedHostKeyboardCommand(event: event) else { return false }
            handledCommands.append(command)
            return true
        }
        let guestShortcut = try keyEvent(characters: "K", modifiers: [.command, .capsLock], keyCode: 40)
        _ = display.performKeyEquivalent(with: guestShortcut)
        display.keyDown(with: guestShortcut)
        #expect(handledCommands.isEmpty)

        let hostShortcut = try keyEvent(characters: "k", modifiers: [.control, .option, .command], keyCode: 40)
        #expect(display.performKeyEquivalent(with: hostShortcut))
        expectNoDifference(handledCommands, [.palette])
    }

    @Test func releasingInputDoesNotChangeTheChosenCapturePreference() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        let display = GuestDisplayView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        window.contentView = display
        display.prefersSystemKeyCapture = true
        #expect(!display.capturesSystemKeys)
        #expect(window.makeFirstResponder(display))
        #expect(display.capturesSystemKeys)
        #expect(window.makeFirstResponder(nil))
        #expect(!display.capturesSystemKeys)
        #expect(display.prefersSystemKeyCapture)
        display.prefersSystemKeyCapture = true
        #expect(!display.capturesSystemKeys)
        #expect(window.makeFirstResponder(display))
        #expect(display.capturesSystemKeys)
    }

    @Test func disablingGuestInputRevokesFocusAndKeepsHostCommandsAvailable() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        let display = GuestDisplayView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        window.contentView = display
        display.prefersSystemKeyCapture = true
        #expect(window.makeFirstResponder(display))
        #expect(display.capturesSystemKeys)

        display.acceptsGuestInput = false

        #expect(window.firstResponder !== display)
        #expect(!display.acceptsFirstResponder)
        #expect(!display.becomeFirstResponder())
        #expect(!display.capturesSystemKeys)
        #expect(display.prefersSystemKeyCapture)
        let ordinary = try keyEvent(characters: "k", modifiers: [], keyCode: 40)
        #expect(!display.performKeyEquivalent(with: ordinary))

        var handledCommands: [ReservedHostKeyboardCommand] = []
        display.reservedShortcutHandler = { event in
            guard let command = ReservedHostKeyboardCommand(event: event) else { return false }
            handledCommands.append(command)
            return true
        }
        let settings = try keyEvent(characters: ",", modifiers: .command, keyCode: 43)
        let release = try keyEvent(characters: "\u{1b}", modifiers: [.control, .option], keyCode: 53)
        #expect(display.performKeyEquivalent(with: settings))
        display.keyDown(with: release)
        expectNoDifference(handledCommands, [.settings, .releaseInput])

        display.acceptsGuestInput = true
        #expect(!display.capturesSystemKeys)
        #expect(window.makeFirstResponder(display))
        #expect(display.capturesSystemKeys)
    }

    private func keyEvent(characters: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
