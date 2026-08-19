import SwiftUI

/// A reusable animated spinner capsule component that overlays any content
struct CapsuleSpinnerView<Content: View>: View {
    @Environment(\.colorScheme) var colorScheme

    let isLooping: Bool
    let color: Color
    let content: (Bool) -> Content

    @State private var isAnimating: Bool = false
    @State private var spinProgress: CGFloat = 0.0
    @State private var spinStartDate: Date? = nil
    @State private var startAnimationTask: Task<Void, Never>? = nil
    @State private var stopAnimationTask: Task<Void, Never>? = nil

    // OPTION 1: Initializer WITH the animating argument
    init(
        isLooping: Bool,
        color: Color,
        @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.isLooping = isLooping
        self.color = color
        self.content = content
    }

    // OPTION 2: Initializer WITHOUT the animating argument
    init(
        isLooping: Bool,
        color: Color,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isLooping = isLooping
        self.color = color
        self.content = { _ in content() }
    }

    var body: some View {
        content(isAnimating)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .overlay(
                Group {
                    if isAnimating {
                        DashedCapsuleBorder(progress: spinProgress)
                            .stroke(color.opacity(0.4), style: StrokeStyle(lineWidth: 2.05, lineCap: .round))
                            .transition(.opacity)
                    } else {
                        Capsule()
                            .stroke(color.opacity(0.4), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .transition(.opacity)
                    }
                }
            )
            .onAppear {
                updateAnimating(isLooping)
            }
            .onChange(of: isLooping) { _, newValue in
                updateAnimating(newValue)
            }
    }

    private func updateAnimating(_ newValue: Bool) {
        if newValue {
            stopAnimationTask?.cancel()
            stopAnimationTask = nil

            guard startAnimationTask == nil else { return }

            spinStartDate = Date()

            startAnimationTask = Task { @MainActor in
                // 1. Fade in the spinning capsule
                withAnimation(.easeInOut(duration: 0.3)) {
                    isAnimating = true
                }

                // 2. Wait for transition
                try? await Task.sleep(for: .seconds(0.3))

                // 3. Reset progress instantly
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    self.spinProgress = 0.0
                }

                // 4. Drive the normalized 0.0 -> 1.0 spin loop
                withAnimation(.linear(duration: 1.333).repeatForever(autoreverses: false)) {
                    self.spinProgress = 1.0
                }

                startAnimationTask = nil
            }
        } else {
            stopAnimationTask?.cancel()

            stopAnimationTask = Task { @MainActor in
                while startAnimationTask != nil {
                    try? await Task.sleep(for: .milliseconds(20))
                    guard !Task.isCancelled else { return }
                }

                let elapsed = spinStartDate.map { Date().timeIntervalSince($0) } ?? 0
                let minimumSpinTime: TimeInterval = 2.0
                let remaining = max(0, minimumSpinTime - elapsed)

                if remaining > 0 {
                    try? await Task.sleep(for: .seconds(remaining))
                    guard !Task.isCancelled else { return }
                }

                // 1. Fade out spinning capsule
                withAnimation(.easeInOut(duration: 0.3)) {
                    isAnimating = false
                }

                // 2. Wait for the transition
                try? await Task.sleep(for: .seconds(0.3))
                guard !Task.isCancelled else { return }

                // 3. Reset animation state
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    self.spinProgress = 0.0
                }

                spinStartDate = nil
            }
        }
    }
}

// MARK: - Custom Self-Measuring Animatable Shape

private struct DashedCapsuleBorder: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let perimeter: CGFloat = w >= h
            ? (2 * (w - h) + .pi * h).rounded()
            : (2 * (h - w) + .pi * w).rounded()

        let dashLength = perimeter * 0.7
        let gapLength = perimeter * 0.3
        let dashPhase = -progress * perimeter

        // ONLY apply dash styling here, NOT the line width
        var style = StrokeStyle(lineCap: .round)
        style.dash = [dashLength, gapLength]
        style.dashPhase = dashPhase

        return Capsule().path(in: rect).strokedPath(style)
    }
}
