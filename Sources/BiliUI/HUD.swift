import SwiftUI

/// 居中弹出的毛玻璃提示，就是 macOS 调音量那种，自己会消失。
public struct HUD: Equatable {
    public let icon: String
    public let text: String

    public init(icon: String, text: String) {
        self.icon = icon
        self.text = text
    }
}

private struct HUDModifier: ViewModifier {

    @Binding var hud: HUD?
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay {
                if let hud {
                    VStack(spacing: 8) {
                        Image(systemName: hud.icon)
                            .font(.system(size: 32, weight: .medium))
                        Text(hud.text)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 22)
                    .frame(minWidth: 130)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.18), value: hud)
            .onChangeCompat(of: hud) { value in
                dismissTask?.cancel()
                guard value != nil else { return }
                dismissTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    guard !Task.isCancelled else { return }
                    hud = nil
                }
            }
    }
}

extension View {
    public func hud(_ hud: Binding<HUD?>) -> some View {
        modifier(HUDModifier(hud: hud))
    }
}
