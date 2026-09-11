import AppKit
import CustomDump
import SwiftUI
import Testing
@testable import Omabox

@MainActor
struct PaletteFocusTests {
    @Test func openingFocusesSearchBeforeImmediateNativeTypingAndRapidReopening() throws {
        let model = PaletteModel()
        let host = NSHostingView(rootView: PaletteFocusHarness(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        let guest = GuestDisplayView(frame: host.bounds)
        host.addSubview(guest)
        guest.prefersSystemKeyCapture = true
        #expect(window.makeFirstResponder(guest))
        #expect(guest.capturesSystemKeys)
        #expect(window.makeFirstResponder(nil))
        #expect(!guest.capturesSystemKeys)
        model.open(commands: [.settings, .releaseKeyboard, .machine])
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()

        let editor = try #require(window.firstResponder as? NSTextView)
        let field = try #require(searchField(in: host))
        #expect(field.currentEditor() === editor)
        editor.insertText("release keyboard", replacementRange: NSRange(location: NSNotFound, length: 0))
        expectNoDifference(editor.string, "release keyboard")
        expectNoDifference(model.query, "release keyboard")

        model.close()
        model.open(commands: [.settings, .machine])
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        let reopenedEditor = try #require(window.firstResponder as? NSTextView)
        let reopenedField = try #require(searchField(in: host))
        #expect(reopenedField.currentEditor() === reopenedEditor)
        reopenedEditor.insertText("machine", replacementRange: NSRange(location: NSNotFound, length: 0))
        expectNoDifference(reopenedEditor.string, "machine")
        expectNoDifference(model.query, "machine")
    }

    @Test func routinePaletteUpdatesPreserveTheNativeCaretAndFocus() throws {
        let model = PaletteModel()
        model.open(commands: [.settings, .releaseKeyboard, .machine])
        let host = NSHostingView(rootView: PaletteFocusHarness(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("settings", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        model.moveSelection(by: 1)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        #expect(window.firstResponder === editor)
        expectNoDifference(editor.selectedRange(), NSRange(location: 3, length: 0))
        expectNoDifference(model.query, "settings")
    }

    @Test func compactResolutionSubmenuFocusesBeforeImmediateTypingAndBackNavigation() throws {
        var updatePresentation: () -> Void = {}
        let model = PaletteModel(onPresentationChanged: { updatePresentation() })
        model.open(commands: [.settings, .resolution], currentResolution: CGSize(width: 1440, height: 900))
        let size = CGSize(width: 512, height: 320)
        let host = NSHostingView(rootView: PaletteFocusHarness(model: model, size: size))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        updatePresentation = { [weak host] in
            host?.needsLayout = true
            host?.layoutSubtreeIfNeeded()
        }
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("resolution", replacementRange: NSRange(location: NSNotFound, length: 0))
        model.selectCommand(.resolution) { _ in Issue.record("Opening a submenu must not execute a desktop action") }

        let resolutionEditor = try #require(window.firstResponder as? NSTextView)
        let resolutionField = try #require(searchField(in: host))
        #expect(resolutionField.currentEditor() === resolutionEditor)
        let fieldFrame = resolutionField.convert(resolutionField.bounds, to: host)
        #expect(host.bounds.contains(fieldFrame))
        expectNoDifference(resolutionEditor.string, "")
        resolutionEditor.insertText("320p", replacementRange: NSRange(location: NSNotFound, length: 0))
        expectNoDifference(model.query, "320p")
        expectNoDifference(model.resolutionResults, [.size512x320])

        model.goBackOrClose()
        let commandEditor = try #require(window.firstResponder as? NSTextView)
        expectNoDifference(commandEditor.string, "resolution")
        expectNoDifference(model.selection, .resolution)
    }

    private func searchField(in view: NSView) -> PaletteTextField? {
        if let field = view as? PaletteTextField { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }
}
