import SwiftUI
import ClrcCore

/// Status circle: a white glyph on the status color, or for `working` a
/// ring with a calmly pulsing centre dot. Always carries the status text
/// for VoiceOver, so color is never the only signal.
struct StatusIcon: View {
    let status: SessionStatus
    var size: CGFloat = 26

    @State private var pulse = false

    var body: some View {
        Group {
            if status == .working {
                ZStack {
                    Circle().stroke(Palette.blue, lineWidth: 2)
                    Circle()
                        .fill(Palette.blue)
                        .frame(width: size * 0.36, height: size * 0.36)
                        .opacity(pulse ? 0.35 : 1)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
                }
            } else {
                Circle()
                    .fill(Palette.status(status))
                    .overlay(
                        Text(status.glyph)
                            .font(.system(size: size * 0.58, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(status.label)
    }
}

/// Small solid dot, e.g. the context check or the connection pill.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

#Preview {
    VStack(spacing: 24) {
        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            HStack(spacing: 16) {
                ForEach(SessionStatus.allCases, id: \.self) { status in
                    VStack {
                        StatusIcon(status: status)
                        Text(status.label).font(.caption2)
                    }
                }
            }
            .padding()
            .background(Palette.bg)
            .environment(\.colorScheme, scheme)
        }
    }
}
