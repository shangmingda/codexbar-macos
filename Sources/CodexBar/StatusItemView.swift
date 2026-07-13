import AppKit

final class StatusItemContentView: NSView {
    var lines: [String] = ["额度 --"] { didSet { needsDisplay = true } }
    var icon: NSImage? { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let iconRect = NSRect(x: 2, y: (bounds.height - 17) / 2, width: 17, height: 17)
        icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)

        let twoLines = lines.count > 1
        let font = NSFont.monospacedDigitSystemFont(ofSize: twoLines ? 8.5 : 11, weight: .medium)
        let color = NSColor.labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.minimumLineHeight = twoLines ? 9.5 : 13
        paragraph.maximumLineHeight = twoLines ? 9.5 : 13
        let text = lines.joined(separator: "\n")
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let measuredHeight = ceil(attributed.boundingRect(with: NSSize(width: bounds.width - 25, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height)
        let y = floor((bounds.height - measuredHeight) / 2)
        let rect = NSRect(x: 23, y: y, width: bounds.width - 25, height: measuredHeight)
        attributed.draw(in: rect)
    }
}
