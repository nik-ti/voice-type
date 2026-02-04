import SwiftUI

/// Floating indicator shown when recording
struct FloatingIndicatorView: View {
    let audioLevel: Float
    let isVisible: Bool
    
    @State private var isPulsing = false
    
    var body: some View {
        ZStack {
            // Background blur
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 100, height: 100)
            
            // Pulsing rings based on audio level
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [.blue.opacity(0.6), .purple.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2
                    )
                    .frame(width: ringSize(for: index), height: ringSize(for: index))
                    .opacity(ringOpacity(for: index))
                    .scaleEffect(isPulsing ? 1.0 + CGFloat(audioLevel) * 0.2 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.3).delay(Double(index) * 0.1),
                        value: isPulsing
                    )
            }
            
            // Main microphone circle
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 60, height: 60)
                .shadow(color: .blue.opacity(0.5), radius: 10, x: 0, y: 5)
            
            // Microphone icon
            Image(systemName: "mic.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white)
            
            // Audio level indicator (inner glow)
            Circle()
                .fill(.white.opacity(Double(audioLevel) * 0.3))
                .frame(width: 60, height: 60)
                .blur(radius: 5)
        }
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.5)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isVisible)
        .onAppear {
            startPulsingAnimation()
        }
    }
    
    private func ringSize(for index: Int) -> CGFloat {
        return 70 + CGFloat(index) * 15
    }
    
    private func ringOpacity(for index: Int) -> Double {
        let baseOpacity = 0.5 - Double(index) * 0.15
        return baseOpacity + Double(audioLevel) * 0.3
    }
    
    private func startPulsingAnimation() {
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            isPulsing = true
        }
    }
}

#Preview {
    ZStack {
        Color.black.opacity(0.3)
        FloatingIndicatorView(audioLevel: 0.5, isVisible: true)
    }
    .frame(width: 200, height: 200)
}
