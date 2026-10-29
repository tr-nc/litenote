import AppKit

/// One scrolling document, one text editor. Task controls belong to this view, not to
/// TextKit's disposable attachment providers. Region geometry is a read-only projection.
final class ChecklistDocumentView: NSView {
    struct Region {
        let id: UUID
        let isChecked: Bool
        var frame: NSRect
        var baselines: [CGFloat]
        let firstLineTop: CGFloat
    }

    static let textInset: CGFloat = 54
    private let editor: NoteTextView
    private let chrome = ChecklistChrome()
    private(set) var regions: [Region] = []
    private var updating = false
    override var isFlipped: Bool { true }

    init(editor: NoteTextView) {
        self.editor = editor
        super.init(frame: editor.frame)
        autoresizingMask = [.width]
        editor.textContainerInset.width = Self.textInset
        addSubview(editor)
        addSubview(chrome)
        chrome.onToggle = { [weak editor] in editor?.toggleTask($0) }
        editor.onPresentationChange = { [weak self] in self?.needsLayout = true }
        needsLayout = true
    }

    required init?(coder: NSCoder) { return nil }

    override func layout() {
        super.layout()
        guard !updating, let layout = editor.textLayoutManager, let storage = editor.textStorage else { return }
        updating = true
        defer { updating = false }
        // NSClipView can autoresize a generic document from its initial zero-width
        // host during constraint installation. The viewport owns document width.
        if let width = enclosingScrollView?.contentSize.width, width > 0, width != bounds.width {
            setFrameSize(NSSize(width: width, height: frame.height))
        }
        if editor.frame.width != bounds.width { editor.setFrameSize(NSSize(width: bounds.width, height: editor.frame.height)) }
        normalizeParagraphs(storage)
        layout.ensureLayout(for: layout.documentRange)
        let origin = editor.textContainerOrigin
        var projected: [Region] = []

        layout.enumerateTextLayoutFragments(from: layout.documentRange.location,
                                           options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            let fragmentOffset = layout.textContentManager!.offset(from: layout.documentRange.location,
                                                                   to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let offset = fragmentOffset + line.characterRange.location
                let top = origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
                let baseline = top + line.glyphOrigin.y
                if offset < storage.length,
                   let marker = storage.attribute(.attachment, at: offset, effectiveRange: nil) as? PaperAttachment,
                   case .task(let id, let checked) = marker.value {
                    projected.append(Region(id: id, isChecked: checked,
                                            frame: NSRect(x: 12, y: top - 8, width: max(0, self.bounds.width - 24), height: 0),
                                            baselines: [], firstLineTop: top))
                }
                if !projected.isEmpty {
                    let index = projected.count - 1
                    projected[index].baselines.append(baseline)
                    let bottom = max(top + line.typographicBounds.height, baseline + 3) + 10
                    projected[index].frame.size.height = max(38, bottom - projected[index].frame.minY)
                }
            }
            return true
        }
        regions = projected
        let height = max(enclosingScrollView?.contentSize.height ?? 0,
                         (regions.last?.frame.maxY ?? 0) + 16)
        if frame.height != height { setFrameSize(NSSize(width: frame.width, height: height)) }
        if editor.frame.height != height { editor.setFrameSize(NSSize(width: bounds.width, height: height)) }
        chrome.frame = bounds
        chrome.update(regions)
    }

    /// Paragraph spacing is presentation-only and derived from structural task starts.
    /// Never add padding characters or extra newlines to the saved/selected content.
    private func normalizeParagraphs(_ storage: NSTextStorage) {
        let string = storage.string as NSString
        var location = 0
        var changes: [(NSRange, NSParagraphStyle)] = []
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            let paragraph = (EditorProjection.attributes(ink: .graphite)[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            if let marker = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? PaperAttachment,
               case .task = marker.value {
                paragraph.paragraphSpacingBefore = range.location == 0 ? 6 : 24
            }
            let current = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            if current != paragraph { changes.append((range, paragraph)) }
            location = NSMaxRange(range)
        }
        if !changes.isEmpty {
            storage.beginEditing()
            for (range, paragraph) in changes { storage.addAttribute(.paragraphStyle, value: paragraph, range: range) }
            storage.endEditing()
        }
    }
}

private final class ChecklistChrome: NSView {
    private var regions: [ChecklistDocumentView.Region] = []
    private var buttons: [UUID: TaskCheckbox] = [:]
    var onToggle: ((UUID) -> Void)?
    override var isFlipped: Bool { true }

    func update(_ regions: [ChecklistDocumentView.Region]) {
        self.regions = regions
        let ids = Set(regions.map(\.id))
        for id in Array(buttons.keys) where !ids.contains(id) {
            buttons.removeValue(forKey: id)?.removeFromSuperview()
        }
        for region in regions {
            let button: TaskCheckbox
            if let existing = buttons[region.id] { button = existing }
            else {
                button = TaskCheckbox(id: region.id)
                button.target = self
                button.action = #selector(toggle(_:))
                buttons[region.id] = button
                addSubview(button)
            }
            button.state = region.isChecked ? .on : .off
            button.frame = NSRect(x: 24, y: region.firstLineTop, width: 22, height: 22)
        }
        needsDisplay = true
    }

    @objc private func toggle(_ button: TaskCheckbox) { onToggle?(button.id) }

    // The overlay never takes text selection, caret, scrolling, or image interactions.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func draw(_ dirtyRect: NSRect) {
        for region in regions where region.frame.intersects(dirtyRect) {
            let border = NSBezierPath(roundedRect: region.frame, xRadius: 6, yRadius: 6)
            PaperPalette.border.setStroke()
            border.lineWidth = 0.75
            border.stroke()
            let rules = NSBezierPath()
            for baseline in region.baselines {
                rules.move(to: NSPoint(x: ChecklistDocumentView.textInset + 5, y: baseline + 3))
                rules.line(to: NSPoint(x: region.frame.maxX - 12, y: baseline + 3))
            }
            PaperPalette.rule.setStroke()
            rules.lineWidth = 0.5
            rules.stroke()
        }
    }
}

private final class TaskCheckbox: NSButton {
    let id: UUID
    init(id: UUID) {
        self.id = id
        super.init(frame: .zero)
        setButtonType(.switch)
        imagePosition = .imageOnly
        title = ""
        setAccessibilityLabel("完成待办")
    }
    required init?(coder: NSCoder) { return nil }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        let color = NSColor.white.withAlphaComponent(state == .on ? 1 : 0.75)
        color.withAlphaComponent(isHighlighted ? 0.20 : 0.06).setFill()
        shape.fill()
        color.setStroke()
        shape.lineWidth = 1.25
        shape.stroke()
        if state == .on {
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + 3, y: rect.midY))
            check.line(to: NSPoint(x: rect.midX - 1, y: rect.maxY - 4))
            check.line(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 4))
            check.lineWidth = 2
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 3, yRadius: 3).fill()
    }
}
