import AppKit
import CodexBarCore

final class StatusItemContentView: NSView {
    var lines: [String] = ["额度 --"] { didSet { needsDisplay = true } }
    var icon: NSImage? { didSet { needsDisplay = true } }
    var speed: NetworkSpeed = .zero { didSet { needsDisplay = true } }

    // A constant width prevents the whole menu bar from shifting whenever a
    // rate changes from B/s to K/s or M/s.
    var preferredWidth: CGFloat { 284 }
    private let speedCellWidth: CGFloat = 55
    private var speedWidth: CGFloat { speedCellWidth * 2 + 4 }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let iconRect = NSRect(x: 2, y: (bounds.height - 17) / 2, width: 17, height: 17)
        icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)

        let twoLines = lines.count > 1
        let font = NSFont.monospacedDigitSystemFont(ofSize: twoLines ? 8.5 : 11, weight: .medium)
        let color = NSColor.labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let textWidth = max(0, bounds.width - 31 - speedWidth)
        let rowHeight: CGFloat = twoLines ? 10 : 14
        let top = floor((bounds.height - rowHeight * CGFloat(lines.count)) / 2)
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(in: NSRect(x: 23, y: top + rowHeight * CGFloat(lines.count - index - 1), width: textWidth, height: rowHeight), withAttributes: attrs)
        }

        let speedFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let speedParagraph = NSMutableParagraphStyle()
        speedParagraph.alignment = .right
        let speedY = floor((bounds.height - 11) / 2)
        var x = bounds.width - speedWidth
        for (symbol, value) in [("↑", speed.uploadBytesPerSecond), ("↓", speed.downloadBytesPerSecond)] {
            let symbolText = NSAttributedString(string: symbol, attributes: [.font: speedFont, .foregroundColor: NSColor.secondaryLabelColor])
            symbolText.draw(at: NSPoint(x: x, y: speedY))
            (NetworkSpeed.compact(value) as NSString).draw(
                in: NSRect(x: x + 10, y: speedY, width: speedCellWidth - 11, height: 12),
                withAttributes: [.font: speedFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: speedParagraph]
            )
            x += speedCellWidth
        }
    }
}
