import AppKit

/// Decorative rules follow TextKit's laid-out baselines, never an independent page grid.
/// Only the unused area below the document is extended with the normal typing rhythm.
@MainActor
enum RuledPaper {
    private static let baselineOffset: CGFloat = 3

    private static let blankLineAdvance: CGFloat = {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        layout.textContainer = NSTextContainer(size: NSSize(width: 1000, height: CGFloat.greatestFiniteMagnitude))
        content.textStorage = NSTextStorage(string: "M\nM", attributes: EditorProjection.attributes(ink: .graphite))
        layout.ensureLayout(for: layout.documentRange)
        var baselines: [CGFloat] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments {
                baselines.append(fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y)
            }
            return true
        }
        precondition(baselines.count == 2 && baselines[1] > baselines[0])
        return baselines[1] - baselines[0]
    }()

    static func draw(in rect: NSRect, editor: NSTextView) {
        guard let layout = editor.textLayoutManager else { return }
        let origin = editor.textContainerOrigin
        let start = layout.textViewportLayoutController.viewportRange?.location ?? layout.documentRange.location
        let path = NSBezierPath()
        var lastRule: CGFloat?
        var reachedEnd = false

        func appendRule(at y: CGFloat) {
            guard y >= rect.minY - 1, y <= rect.maxY + 1 else { return }
            path.move(to: NSPoint(x: editor.bounds.minX, y: y))
            path.line(to: NSPoint(x: editor.bounds.maxX, y: y))
        }

        // Start at the viewport's paragraph and stop after the damaged region. Do not
        // force layout of an entire long note just to decorate its visible portion.
        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            if origin.y + fragment.layoutFragmentFrame.minY > rect.maxY + 1 { return false }
            for line in fragment.textLineFragments {
                let y = origin.y + fragment.layoutFragmentFrame.minY
                    + line.typographicBounds.minY + line.glyphOrigin.y + baselineOffset
                appendRule(at: y)
                lastRule = y
            }
            reachedEnd = fragment.rangeInElement.endLocation.compare(layout.documentRange.endLocation) != .orderedAscending
            return true
        }

        // No rules are synthesized inside content: a tall image can increase its line
        // height without being sliced by the paper pattern or constrained to a grid.
        if reachedEnd, let lastRule {
            let skipped = max(1, ceil((rect.minY - lastRule) / blankLineAdvance))
            for y in stride(from: lastRule + skipped * blankLineAdvance, through: rect.maxY + 1, by: blankLineAdvance) {
                appendRule(at: y)
            }
        }

        NSColor(srgbRed: 0.47, green: 0.58, blue: 0.70, alpha: 0.18).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
