import AppKit
import SwiftUI

/// The popover keeps the system material; these tones sit on top of it.
enum Palette {
    static let card = adaptive(0xFFFFFF, 0xFFFFFF, alpha: 0.86, darkAlpha: 0.07)
    static let border = adaptive(0x000000, 0xFFFFFF, alpha: 0.09, darkAlpha: 0.10)
    static let divider = adaptive(0x000000, 0xFFFFFF, alpha: 0.06, darkAlpha: 0.07)
    static let fill = adaptive(0x000000, 0xFFFFFF, alpha: 0.05, darkAlpha: 0.09)
    static let track = adaptive(0x000000, 0xFFFFFF, alpha: 0.08, darkAlpha: 0.12)
    static let secondary = adaptive(0x6B6B70, 0xA1A1A6)
    static let accent = adaptive(0xB5553A, 0xE38B6E)
    static let onAccent = adaptive(0xFFFFFF, 0x1D1D1F)
    static let accentTint = adaptive(0xB5553A, 0xE38B6E, alpha: 0.12, darkAlpha: 0.18)
    static let accentText = adaptive(0x8A3F28, 0xF2B49E)
    static let live = adaptive(0x2FB866, 0x4ED17E)
    static let success = adaptive(0x1E7A44, 0x4ED17E)
    static let successTint = adaptive(0x2FB866, 0x4ED17E, alpha: 0.15, darkAlpha: 0.14)
    static let warning = adaptive(0x935300, 0xFFB340)
    static let warningTint = adaptive(0xF2A33A, 0xFFB340, alpha: 0.18, darkAlpha: 0.14)
    static let warningFill = adaptive(0xE8912D, 0xFFB340)
    static let danger = adaptive(0xB8332A, 0xFF8A80)
    static let dangerTint = adaptive(0xE5483D, 0xFF6B61, alpha: 0.12, darkAlpha: 0.16)
    static let dangerFill = adaptive(0xE5483D, 0xFF6B61)
    static let avatars = [accent, adaptive(0x4C6FA5, 0x6F8FC4), adaptive(0x3F7D5A, 0x6DBE8E),
                          adaptive(0x7A5299, 0xB08AD6), adaptive(0x5B6770, 0x9AA7B0)]

    static func adaptive(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1, darkAlpha: CGFloat? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark, darkAlpha ?? alpha) : color(light, alpha)
        })
    }

    private static func color(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension View {
    func card(highlight: Color? = nil, radius: CGFloat = 12) -> some View {
        background(Palette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(highlight ?? Palette.border, lineWidth: highlight == nil ? 1 : 1.5)
            }
    }

    func hoverHighlight(radius: CGFloat = 7) -> some View { modifier(HoverHighlight(radius: radius)) }
}

private struct HoverHighlight: ViewModifier {
    let radius: CGFloat
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(hovering ? Palette.fill : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
    }
}

struct ActionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    var kind: Kind = .primary
    var size: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View { StyledButton(configuration: configuration, kind: kind, size: size) }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let size: CGFloat
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: size, weight: kind == .plain ? .medium : .semibold))
                .lineLimit(1)
                .foregroundStyle(kind == .primary ? Palette.onAccent : (kind == .plain ? Palette.secondary : Color.primary))
                .padding(.horizontal, size > 12 ? 14 : 11).padding(.vertical, size > 12 ? 6 : 4.5)
                .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    if kind == .secondary {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.border)
                    }
                }
                .contentShape(Rectangle())
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .onHover { hovering = $0 }
        }

        private var background: Color {
            switch kind {
            case .primary: return Palette.accent.opacity(hovering && enabled ? 0.88 : 1)
            case .secondary: return hovering && enabled ? Palette.fill : Palette.card
            case .plain: return hovering && enabled ? Palette.fill : .clear
            }
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.secondary)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .hoverHighlight()
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == ActionButtonStyle {
    static var primaryAction: ActionButtonStyle { ActionButtonStyle(kind: .primary) }
    static var secondaryAction: ActionButtonStyle { ActionButtonStyle(kind: .secondary) }
    static var plainAction: ActionButtonStyle { ActionButtonStyle(kind: .plain) }
}

/// An ellipsis or icon menu without the default bezel.
struct IconMenu<Content: View>: View {
    let systemImage: String
    let help: String
    var size: CGFloat = 28
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: systemImage).font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Palette.secondary)
        .frame(width: size, height: size)
        .hoverHighlight()
        .help(help).accessibilityLabel(help)
    }
}

struct Avatar: View {
    let label: String
    let color: Color
    var size: CGFloat = 32
    var body: some View {
        Text(label.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(Palette.onAccent)
            .frame(width: size, height: size)
            .background(color, in: Circle())
            .accessibilityHidden(true)
    }
}

struct SectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title; self.trailing = trailing
    }
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Palette.secondary).accessibilityAddTraits(.isHeader)
            Spacer()
            trailing()
        }
    }
}

struct AppGlyph: View {
    var size: CGFloat = 32
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Image(nsImage: CswitchIcon.glyphImage(size: size * 0.62,
                                              color: scheme == .dark ? NSColor(white: 0.11, alpha: 1) : .white))
            .frame(width: size, height: size)
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

enum Format {
    static func plan(_ raw: String?) -> String? {
        guard var value = raw?.lowercased(), !value.isEmpty else { return nil }
        if value.hasPrefix("claude_") { value.removeFirst("claude_".count) }
        return value.replacingOccurrences(of: "_", with: " ").uppercased()
    }

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Wraps chips onto new lines when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}
