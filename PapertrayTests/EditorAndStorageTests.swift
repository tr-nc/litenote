import AppKit
import XCTest
@testable import Papertray

@MainActor
final class EditorAndStorageTests: XCTestCase {
    var root: URL!
    var attachments: AttachmentStore!
    var store: NoteStore!
    var clipboard: NSPasteboard!
    var controllers: [NoteController] = []
    var glass: GlassPreferences!
    private var preferencesSuite: String!

    override func setUpWithError() throws {
        preferencesSuite = "local.papertray.glass-tests.\(UUID())"
        glass = GlassPreferences(defaults: UserDefaults(suiteName: preferencesSuite)!)
        var style = GlassStyle()
        style.grainStrength = 0 // Pixel alignment tests isolate rules from decorative noise.
        style.tintStrength = 0.85
        glass.update(style)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Papertray 测试 \(UUID())")
        attachments = try AttachmentStore(root: root)
        store = try NoteStore(root: root, attachments: attachments)
        clipboard = NSPasteboard(name: .init("local.papertray.tests.\(UUID())"))
    }

    override func tearDownWithError() throws {
        for controller in controllers { controller.window?.close() }
        controllers = []
        glass = nil
        UserDefaults().removePersistentDomain(forName: preferencesSuite)
        clipboard.releaseGlobally()
        try FileManager.default.removeItem(at: root)
    }

    func editor(kind: PaperKind = .ruled) throws -> NoteController {
        let controller = try NoteController(document: NoteDocument(kind: kind), store: store, attachments: attachments,
                                            frame: NSRect(x: 0, y: 0, width: 360, height: 440), glass: glass)
        controller.editor.clipboard = clipboard
        controller.window?.makeFirstResponder(controller.editor)
        controllers.append(controller)
        return controller
    }

    func png() -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<24 {
            for x in 0..<32 {
                let offset = y * image.bytesPerRow + x * 4
                image.bitmapData![offset] = x < 16 ? 30 : 250
                image.bitmapData![offset + 1] = 120
                image.bitmapData![offset + 2] = x < 16 ? 230 : 30
                image.bitmapData![offset + 3] = 255
            }
        }
        return image.representation(using: .png, properties: [:])!
    }

    func testLongPaperAndOrdinaryNewlinesUseOneTextKit2Document() throws {
        let controller = try editor()
        let view = controller.editor
        let longText = String(repeating: "长正文 👩🏽‍💻 e\u{301} 内容\n", count: 120)
        view.insertText(longText, replacementRange: view.selectedRange())
        view.insertLineBreak(nil)
        view.insertText("继续", replacementRange: view.selectedRange())
        view.insertNewline(nil)
        view.insertText("下一行", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, longText + "\n继续\n下一行")
        XCTAssertNotNil(view.textLayoutManager)
        try controller.flush()
        XCTAssertEqual(store.loadAll().notes.first?.content, controller.noteDocument.content)
    }

    func testReturnAtCaretAndBackspaceAreOrdinaryTextEdits() throws {
        let controller = try editor()
        let view = controller.editor
        view.insertText("前后", replacementRange: view.selectedRange())
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "前\n后")
        view.deleteBackward(nil)
        XCTAssertEqual(controller.noteDocument.content, .ruled([.text("前后", .graphite)]))
    }

    func testSelectAllDeleteLeavesAnEmptyPaperAndCanUndo() throws {
        let controller = try editor()
        let view = controller.editor
        view.insertText("第一行\n第二行", replacementRange: view.selectedRange())
        view.breakUndoCoalescing()
        view.undoManager?.removeAllActions()
        view.selectAll(nil)
        view.deleteBackward(nil)
        XCTAssertEqual(controller.noteDocument.content, .ruled([]))
        XCTAssertEqual(view.string, "")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "第一行\n第二行")
        view.undoManager?.redo()
        XCTAssertEqual(view.string, "")
    }

    func testLegacyColoredTextRendersWhiteWithoutRewritingItsMetadata() throws {
        var document = NoteDocument(kind: .ruled)
        document.content = .ruled(Ink.allCases.map { .text("\($0.rawValue) ", $0) })
        try store.save(document)
        let controller = try NoteController(document: document, store: store, attachments: attachments,
                                            frame: NSRect(x: 0, y: 0, width: 360, height: 440), glass: glass)
        controllers.append(controller)
        let view = controller.editor
        view.textStorage?.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: view.string.utf16.count)) { color, _, _ in
            XCTAssertEqual(color as? NSColor, .white)
        }
        XCTAssertEqual(controller.noteDocument, document)
        try controller.flush()
        XCTAssertEqual(store.loadAll().notes.first?.content, document.content)
        view.insertText("新", replacementRange: NSRange(location: view.string.utf16.count, length: 0))
        XCTAssertEqual(view.textStorage?.attribute(.foregroundColor, at: view.string.utf16.count - 1, effectiveRange: nil) as? NSColor, .white)
        XCTAssertEqual(view.insertionPointColor, .white)
        view.undoManager?.undo()
        XCTAssertEqual(controller.noteDocument.content, document.content)
    }

    func testPasteMultilineTextNormalizesFormatting() throws {
        let controller = try editor()
        clipboard.setString("一\n二\n三 👩🏽‍💻", forType: .string)
        controller.editor.paste(nil)
        XCTAssertEqual(controller.noteDocument.content, .ruled([.text("一\n二\n三 👩🏽‍💻", .graphite)]))
    }

    func testImagePasteCommitsFileBeforeDocumentAndCopiesOnlyPlainText() async throws {
        let controller = try editor()
        clipboard.setData(png(), forType: .png)
        controller.editor.paste(nil)
        for _ in 0..<250 {
            if !controller.noteDocument.attachmentIDs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let id = try XCTUnwrap(controller.noteDocument.attachmentIDs.first)
        let url = try attachments.verifiedURL(for: id)
        XCTAssertNotNil(NSImage(contentsOf: url))
        controller.editor.selectAll(nil)
        controller.editor.copy(nil)
        // AppKit adds its legacy string alias; neither type is image or public rich text.
        XCTAssertTrue(Set(clipboard.types ?? []).isSubset(of: [.string, .init("NSStringPboardType")]))
        XCTAssertTrue(clipboard.types?.contains(.string) == true)
        XCTAssertEqual(clipboard.string(forType: .string), url.path + "\n")
        XCTAssertEqual(store.loadAll().notes.first?.attachmentIDs, [id])
        controller.editor.setSelectedRange(NSRange(location: 0, length: 1))
        controller.editor.copy(nil)
        XCTAssertEqual(clipboard.string(forType: .string), url.path + "\n")
        controller.editor.cut(nil)
        XCTAssertEqual(controller.noteDocument.attachmentIDs, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(clipboard.string(forType: .string), url.path + "\n")
        try controller.flush()
        let reloaded = try AttachmentStore(root: root)
        XCTAssertEqual(try reloaded.verifiedURL(for: id), url)
    }

    func testPartialCopyRespectsSelectionAcrossNewlines() throws {
        let controller = try editor()
        let view = controller.editor
        view.insertText("甲乙丙\n丁戊", replacementRange: view.selectedRange())
        view.setSelectedRange(NSRange(location: 1, length: 4))
        view.copy(nil)
        XCTAssertEqual(clipboard.string(forType: .string), "乙丙\n丁")
        view.setSelectedRange(NSRange(location: 0, length: 1))
        view.copy(nil)
        XCTAssertEqual(clipboard.string(forType: .string), "甲")
    }

    func testMissingImageBlocksCopyAndCutWithoutTouchingTextOrClipboard() async throws {
        let controller = try editor(kind: .ruled)
        let id = try await attachments.importImage(png())
        controller.editor.insertText(try EditorProjection.image(id, store: attachments), replacementRange: NSRange(location: 0, length: 0))
        try controller.flush()
        try FileManager.default.removeItem(at: attachments.verifiedURL(for: id))
        clipboard.setString("原剪贴板", forType: .string)
        var errors = 0
        controller.editor.reportError = { _ in errors += 1 }
        controller.editor.selectAll(nil)
        controller.editor.cut(nil)
        XCTAssertEqual(errors, 1)
        XCTAssertEqual(controller.noteDocument.attachmentIDs, [id])
        XCTAssertEqual(clipboard.string(forType: .string), "原剪贴板")
    }

    func testProjectionRoundTripPreservesLegacyColorsParagraphsAndImages() async throws {
        let id = try await attachments.importImage(png())
        let content = NoteContent.ruled([
            .text("中文\n\nemoji 🥳", .purple), .image(id), .text("\n尾", .green)
        ])
        let projected = try EditorProjection.render(content, store: attachments)
        XCTAssertEqual(EditorProjection.parse(projected), content)
    }

    func testLongPaperScrollsWithImagesWithoutSwitchingTextKit() async throws {
        let controller = try editor()
        let view = controller.editor
        view.insertText("检查界面\n", replacementRange: view.selectedRange())
        let id = try await attachments.importImage(png())
        view.insertText(try EditorProjection.image(id, store: attachments), replacementRange: view.selectedRange())
        view.insertLineBreak(nil)
        view.insertText(String(repeating: "长正文会连续滚动。\n", count: 70), replacementRange: view.selectedRange())
        controller.open()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let manager = try XCTUnwrap(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        view.scrollRangeToVisible(NSRange(location: view.string.utf16.count, length: 0))
        XCTAssertGreaterThan(view.frame.height, view.enclosingScrollView!.contentSize.height * 3)
        XCTAssertTrue(view.enclosingScrollView?.documentView === view)
        XCTAssertEqual(controller.noteDocument.attachmentIDs, [id])
    }

    func testOuterWindowFrameRestoresWithoutGrowingTitlebar() throws {
        let first = try editor(kind: .ruled)
        let expected = NSRect(x: 0, y: 0, width: 360, height: 440)
        XCTAssertEqual(first.window?.frame, expected)
        let restored = try NoteController(document: first.noteDocument, store: store, attachments: attachments,
                                          frame: expected, glass: glass)
        controllers.append(restored)
        XCTAssertEqual(restored.window?.frame, expected)
    }

    func testExportedImageCanBeReadOutsideApp() async throws {
        // Retained integration evidence, not user data or the production storage location.
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("papertray-validation", isDirectory: true)
        let imageStore = try AttachmentStore(root: evidence)
        let id = try await imageStore.importImage(png())
        let source = try EditorProjection.image(id, store: imageStore)
        let output = try ClipboardExporter.text(from: source, range: NSRange(location: 0, length: 1), store: imageStore)
        try output.write(to: evidence.appendingPathComponent("clipboard.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(output.hasPrefix("/"))
        XCTAssertNotNil(NSImage(contentsOfFile: output.trimmingCharacters(in: .newlines)))
    }

    func testRejectsInvalidImageAndDoesNotWriteAttachment() async throws {
        do {
            _ = try await attachments.importImage(Data("not an image".utf8))
            XCTFail("Should reject")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: attachments.directory.path), [])
    }

    func testStaleSaveCannotOverwriteLatestAndBackupIsPreviousValidRevision() throws {
        var note = NoteDocument(kind: .ruled)
        try store.save(note)
        note.revision = 2
        note.content = .ruled([.text("新", .blue)])
        try store.save(note)
        var stale = note
        stale.revision = 1
        stale.content = .ruled([.text("旧", .red)])
        try store.save(stale)
        XCTAssertEqual(store.loadAll().notes, [note])
        let backup = try JSONDecoder().decode(NoteDocument.self, from: Data(contentsOf: root.appendingPathComponent("backups/\(note.id).json")))
        XCTAssertEqual(backup.revision, 0)
    }

    func testDocumentCannotCommitMissingAttachment() throws {
        var note = NoteDocument(kind: .ruled)
        note.content = .ruled([.image(UUID())])
        XCTAssertThrowsError(try store.save(note))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("notes").path), [])
    }

    func testCorruptionAndFutureSchemaRemainUntouched() throws {
        for data in [Data("{broken".utf8), Data("{\"schemaVersion\":99}".utf8)] {
            let id = UUID()
            let url = root.appendingPathComponent("notes/\(id).json")
            try data.write(to: url)
            let loaded = store.loadAll()
            XCTAssertFalse(loaded.errors.isEmpty)
            XCTAssertTrue(loaded.notes.isEmpty)
            var replacement = NoteDocument(kind: .ruled)
            replacement.id = id
            XCTAssertThrowsError(try store.save(replacement))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testFailedWriteKeepsEditorAndRetrySavesIt() throws {
        let controller = try editor(kind: .ruled)
        let directory = root.appendingPathComponent("notes")
        try FileManager.default.removeItem(at: directory)
        try Data("blocked".utf8).write(to: directory)
        controller.editor.insertText("不能丢", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertThrowsError(try controller.flush())
        XCTAssertEqual(controller.editor.string, "不能丢")
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try controller.flush()
        XCTAssertEqual(store.loadAll().notes.first?.content, .ruled([.text("不能丢", .graphite)]))
    }
}
