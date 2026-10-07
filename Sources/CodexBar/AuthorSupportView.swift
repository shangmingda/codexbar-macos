import AppKit
import SwiftUI

struct AuthorSupportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    private let email = "mingda71@163.com"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(nsImage: CodexBarBrand.image(size: 26)).frame(width: 26, height: 26)
                Text("CodexBar").font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("关闭")
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Label("给我提建议", systemImage: "bubble.left")
                    .font(.system(size: 12, weight: .semibold))
                Text("想法、建议，或使用中遇到的问题，欢迎写信给我。")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "envelope").foregroundStyle(.secondary)
                    Link(email, destination: URL(string: "mailto:mingda71@163.com?subject=CodexBar%20%E5%BB%BA%E8%AE%AE")!)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(email, forType: .string)
                    } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.borderless).help(copied ? "已复制" : "复制邮箱")
                        .accessibilityLabel(copied ? "邮箱已复制" : "复制邮箱")
                }
                .font(.system(size: 11, weight: .medium))
                .padding(11).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("支持作者", systemImage: "heart").font(.system(size: 12, weight: .semibold))
                Text("如果 CodexBar 帮你省了时间，可以请我喝杯咖啡。")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    if let url = Bundle.main.url(forResource: "SupportAuthor", withExtension: "png"),
                       let image = NSImage(contentsOf: url) {
                        // Reuse the author's original QR unchanged, showing the
                        // same crop as the accepted PMure support view.
                        Image(nsImage: image).resizable().interpolation(.none)
                            .frame(width: 254.16, height: 256.4)
                            .offset(x: -0.0, y: 23.0)
                            .frame(width: 178, height: 178).clipped()
                            .padding(9).background(.white, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("作者的支付宝收款码")
                    } else {
                        Text("收款码暂不可用").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text("支付宝扫码 · 自愿支持")
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(20).frame(width: 330)
        .background(.ultraThinMaterial)
    }
}
