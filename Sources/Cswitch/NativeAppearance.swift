import SwiftUI

extension View {
    func nativeControls() -> some View { modifier(NativeControlAppearance()) }
    func nativePrimaryAction() -> some View { modifier(NativePrimaryAction()) }
    func nativeHoverSurface() -> some View { modifier(NativeHoverSurface()) }
}

private struct NativeControlAppearance: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                content.buttonStyle(.glass)
            }
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct NativePrimaryAction: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct NativeHoverSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.15)) }
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        }
    }
}
