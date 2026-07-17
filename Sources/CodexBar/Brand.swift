import AppKit
import SwiftUI

struct CodexBarLogo: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(red: 0.79, green: 0.82, blue: 0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .stroke(Color.white.opacity(0.58), lineWidth: max(0.5, size * 0.018))
                }

            CodexCShape()
                .stroke(
                    Color(red: 0.07, green: 0.08, blue: 0.10),
                    style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round)
                )
                .padding(size * 0.23)

            Capsule()
                .fill(Color(red: 0.07, green: 0.08, blue: 0.10))
                .frame(width: size * 0.26, height: size * 0.11)
                .offset(x: size * 0.13)

            Circle()
                .fill(Color(red: 0.22, green: 0.85, blue: 0.42))
                .overlay(Circle().stroke(Color.white, lineWidth: max(1, size * 0.038)))
                .frame(width: size * 0.15, height: size * 0.15)
                .offset(x: size * 0.265)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.22), radius: size * 0.07, y: size * 0.04)
        .accessibilityHidden(true)
    }
}

private struct CodexCShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: .degrees(48),
            endAngle: .degrees(312),
            clockwise: false
        )
        return path
    }
}

@MainActor
enum CodexBarBrand {
    static func image(size: CGFloat) -> NSImage {
        let renderer = ImageRenderer(content: CodexBarLogo(size: size))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage(size: NSSize(width: size, height: size))
    }
}
