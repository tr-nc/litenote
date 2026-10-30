import AppKit
import XCTest
@testable import Litenote

extension EditorAndStorageTests {
    func testImageOnlyClipboardEnablesPasteAndCommandVImportsIt() async throws {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            let controller = try editor()
            let view = controller.editor
            clipboard.clearContents()
            let data = type == .png ? png() : try XCTUnwrap(NSBitmapImageRep(data: png())?.representation(using: .tiff, properties: [:]))
            clipboard.setData(data, forType: type)
            let (menu, item) = pasteMenu(for: view)
            menu.update()
            XCTAssertTrue(item.isEnabled, "Image-only \(type.rawValue) must enable the real paste command")
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                      timestamp: 0, windowNumber: controller.window!.windowNumber,
                                                      context: nil, characters: "v", charactersIgnoringModifiers: "v",
                                                      isARepeat: false, keyCode: 9))
            XCTAssertTrue(menu.performKeyEquivalent(with: event), "Command-V must reach the custom import path")
            for _ in 0..<250 {
                if !controller.noteDocument.attachmentIDs.isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let id = try XCTUnwrap(controller.noteDocument.attachmentIDs.first)
            XCTAssertNoThrow(try attachments.verifiedURL(for: id))
            XCTAssertEqual(controller.noteDocument.attachmentIDs.count, 1)
            XCTAssertFalse(view.importsGraphics, "Do not enable native imports that bypass AttachmentStore")
            XCTAssertTrue(view.isEditable)
        }
    }

    func testPasteValidationUsesSupportedFormatsAndEditorStateWithoutConsumingTheClipboard() throws {
        let controller = try editor()
        let view = controller.editor
        let sourceURL = root.appendingPathComponent("source.png")
        try png().write(to: sourceURL)
        let actions = [#selector(NSText.paste(_:)), #selector(NSTextView.pasteAsPlainText(_:)),
                       #selector(NSTextView.pasteAsRichText(_:))]
        for action in actions {
            let (menu, item) = pasteMenu(for: view, action: action)
            for type in [NSPasteboard.PasteboardType.png, .tiff, .string, .fileURL, .init("local.litenote.unsupported")] {
                clipboard.clearContents()
                // Validation checks offered formats only; it must not decode or import.
                if type == .fileURL { clipboard.setString(sourceURL.absoluteString, forType: type) }
                else { clipboard.setData(Data("offered payload".utf8), forType: type) }
                let changeCount = clipboard.changeCount
                menu.update()
                XCTAssertEqual(item.isEnabled, [.png, .tiff, .string].contains(type), "\(action): \(type.rawValue)")
                XCTAssertEqual(clipboard.changeCount, changeCount)
                XCTAssertTrue(controller.noteDocument.attachmentIDs.isEmpty)
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: attachments.directory.path).isEmpty)
            }
            clipboard.clearContents()
            menu.update()
            XCTAssertFalse(item.isEnabled)
            clipboard.setString("文字", forType: .string)
            view.isEditable = false
            menu.update()
            XCTAssertFalse(item.isEnabled)
            view.paste(nil)
            XCTAssertEqual(view.string, "", "Direct paste must also respect a read-only editor")
            view.isEditable = true
            menu.update()
            XCTAssertTrue(item.isEnabled)
        }
    }

    func testRichClipboardUsesPlainTextInsteadOfImportingNativeFormatting() throws {
        let controller = try editor()
        let view = controller.editor
        let rich = NSAttributedString(string: "来源文字", attributes: [.font: NSFont.boldSystemFont(ofSize: 36),
                                                                   .foregroundColor: NSColor.red])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length),
                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        clipboard.setData(rtf, forType: .rtf)
        clipboard.setString("来源文字", forType: .string)
        let (menu, item) = pasteMenu(for: view)
        menu.update()
        XCTAssertTrue(item.isEnabled)
        menu.performActionForItem(at: 0)
        XCTAssertEqual(view.string, "来源文字")
        XCTAssertEqual(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, .systemFont(ofSize: 16))
        XCTAssertEqual(view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .white)
        XCTAssertTrue(controller.noteDocument.attachmentIDs.isEmpty)
    }

    func testImportDisablesPasteUntilCompletionAndRejectsASecondCommand() async throws {
        let controller = try editor()
        let view = controller.editor
        clipboard.setData(png(), forType: .png)
        let (menu, item) = pasteMenu(for: view)
        view.paste(nil)
        XCTAssertTrue(view.importing)
        menu.update()
        XCTAssertFalse(item.isEnabled)
        view.paste(nil)
        for _ in 0..<250 {
            if !view.importing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(view.importing)
        XCTAssertEqual(controller.noteDocument.attachmentIDs.count, 1)
        menu.update()
        XCTAssertTrue(item.isEnabled)
    }

    private func pasteMenu(for view: NoteTextView, action: Selector = #selector(NSText.paste(_:))) -> (NSMenu, NSMenuItem) {
        let menu = NSMenu(title: "编辑")
        let item = NSMenuItem(title: "粘贴", action: action, keyEquivalent: "v")
        item.keyEquivalentModifierMask = [.command]
        item.target = view
        menu.addItem(item)
        return (menu, item)
    }
}
