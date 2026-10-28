import AppKit

/// The sole owner of paper membership and visibility. A shortcut changes one workspace,
/// not a collection of independently toggled windows (which can drift out of sync).
@MainActor
final class PaperWorkspace {
    private let tray: ToolTrayController
    private let preferences: UserDefaults
    private(set) var notes: [UUID: NoteController] = [:]
    private(set) var isVisible = false
    private var lastFocusedID: UUID?
    private var isChangingVisibility = false

    var lastFocusedNote: NoteController? {
        lastFocusedID.flatMap { notes[$0] }
    }

    init(tray: ToolTrayController, preferences: UserDefaults) {
        self.tray = tray
        self.preferences = preferences
        tray.onDismiss = { [weak self] in
            do { try self?.hide() }
            catch { NSApp.presentError(error) }
        }
    }

    func add(_ note: NoteController) {
        guard !note.isDeleted else { return }
        let id = note.noteDocument.id
        notes[id] = note
        note.onFocus = { [weak self] note in
            guard let self, self.isVisible, !self.isChangingVisibility,
                  self.notes[note.noteDocument.id] === note else { return }
            self.lastFocusedID = note.noteDocument.id
        }
        note.onHideRequested = { [weak self, weak note] in
            do { try self?.hide() }
            catch { note?.editor.reportError(error) }
        }
        note.onDelete = { [weak self] note in
            guard let self else { return }
            self.notes.removeValue(forKey: note.noteDocument.id)
            if self.lastFocusedID == note.noteDocument.id { self.lastFocusedID = nil }
            self.preferences.removeObject(forKey: "visible.\(note.noteDocument.id)")
            self.preferences.removeObject(forKey: "frame.\(note.noteDocument.id)")
        }
        if isVisible { note.present(focus: false) }
    }

    func restoreVisibility(legacyVisible: Bool, activate: Bool = true) {
        let visible = preferences.object(forKey: "workspaceVisible") as? Bool ?? legacyVisible
        if visible { show(activate: activate) }
        else { preferences.set(false, forKey: "workspaceVisible") }
    }

    func toggle(activate: Bool = true) throws {
        if isVisible { try hide() }
        else { show(activate: activate) }
    }

    func show(focusing id: UUID? = nil, activate: Bool = true) {
        let target = id.flatMap { notes[$0] } ?? lastFocusedNote
            ?? notes.values.max { $0.noteDocument.createdAt < $1.noteDocument.createdAt }
        // Ordering windows can transiently make another paper key. Only the
        // final focus destination should replace the user's remembered paper.
        isChangingVisibility = true
        defer { isChangingVisibility = false }
        for note in notes.values { note.present(focus: false) }
        tray.show(activate: activate && target == nil)
        if activate, let target {
            target.open()
            lastFocusedID = target.noteDocument.id
        }
        isVisible = true
        preferences.set(true, forKey: "workspaceVisible")
    }

    func hide() throws {
        // Flush every note before hiding any window. Failure leaves the whole group visible.
        for note in notes.values { try note.prepareToHide() }
        isChangingVisibility = true
        defer { isChangingVisibility = false }
        tray.hide()
        for note in notes.values { note.window?.orderOut(nil) }
        isVisible = false
        preferences.set(false, forKey: "workspaceVisible")
    }
}
