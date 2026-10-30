import AppKit

/// One persistent paper and one visibility operation. There is no membership,
/// creation, deletion, or document switching API.
@MainActor
final class PaperWorkspace {
    let note: NoteController
    private let preferences: UserDefaults
    var isVisible: Bool { note.window?.isVisible == true }

    init(note: NoteController, preferences: UserDefaults) {
        self.note = note
        self.preferences = preferences
        note.onHideRequested = { [weak self, weak note] in
            do { try self?.hide() }
            catch { note?.editor.reportError(error) }
        }
    }

    func restoreVisibility(activate: Bool = true) {
        let visible = preferences.object(forKey: "workspaceVisible") as? Bool
            ?? preferences.object(forKey: "visible.\(note.noteDocument.id)") as? Bool ?? true
        if visible { show(activate: activate) }
    }

    func toggle(activate: Bool = true) throws {
        if isVisible { try hide() }
        else { show(activate: activate) }
    }

    func show(activate: Bool = true) {
        note.present(focus: activate)
        preferences.set(true, forKey: "workspaceVisible")
    }

    func hide() throws {
        // A failed save/import leaves the same paper visible and editable.
        try note.prepareToHide()
        note.window?.orderOut(nil)
        preferences.set(false, forKey: "workspaceVisible")
    }
}
