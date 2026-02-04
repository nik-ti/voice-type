import SwiftUI

/// Elegant floating indicator - minimalist style with stop button for locked mode
struct FloatingIndicatorView: View {
    let audioLevel: Float
    let isVisible: Bool
    let isLocked: Bool
    var onStop: (() -> Void)? = nil
    
    var body: some View {
        HStack(spacing: 10) {
            // Waveform bars
            HStack(spacing: 2.5) {
                ForEach(0..<10, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.7))
                        .frame(width: 2, height: 2)
                        .scaleEffect(y: waveformScale(for: index), anchor: .center)
                        .animation(
                            .easeInOut(duration: 0.08),
                            value: audioLevel
                        )
                }
            }
            
            // Stop button - only shows in locked mode
            if isLocked {
                Button(action: { onStop?() }) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.red)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color(white: 0.12))
        )
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.9)
        .animation(.easeOut(duration: 0.2), value: isVisible)
        .animation(.easeOut(duration: 0.15), value: isLocked)
    }
    
    private func waveformScale(for index: Int) -> CGFloat {
        let baseScale: CGFloat = 1.0
        let maxScale: CGFloat = 5.0
        
        let centerOffset = abs(CGFloat(index) - 4.5) / 4.5
        let wave = sin(CGFloat(index) * 0.9 + CGFloat(audioLevel) * 15)
        let scale = baseScale + (maxScale - baseScale) * CGFloat(audioLevel) * (1.0 - centerOffset * 0.3) * (0.5 + wave * 0.5)
        
        return max(1.0, min(maxScale, scale))
    }
}

#Preview {
    ZStack {
        Color.gray
        VStack(spacing: 20) {
            FloatingIndicatorView(audioLevel: 0.3, isVisible: true, isLocked: false)
            FloatingIndicatorView(audioLevel: 0.5, isVisible: true, isLocked: true)
        }
    }
    .frame(width: 200, height: 150)
}
