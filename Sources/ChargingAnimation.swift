import SwiftUI
import AppKit

// MARK: - Charging Animation View
struct ChargingAnimationView: View {
    @State private var boltScale: CGFloat = 0.3
    @State private var boltOpacity: Double = 0.0
    @State private var glowOpacity: Double = 0.0
    @State private var glowScale: CGFloat = 0.5
    @State private var ringScale: CGFloat = 0.6
    @State private var ringOpacity: Double = 0.0
    @State private var percentOpacity: Double = 0.0
    
    var batteryLevel: Int = 100
    
    var body: some View {
        ZStack {
            // Background dim
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            
            // Glow circle
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.green.opacity(0.4),
                            Color.green.opacity(0.15),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 180
                    )
                )
                .frame(width: 300, height: 300)
                .scaleEffect(glowScale)
                .opacity(glowOpacity)
            
            // Ring pulse
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.green.opacity(0.6),
                            Color.mint.opacity(0.3)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
                .frame(width: 140, height: 140)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)
            
            // Bolt icon
            VStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 72, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.green, Color.mint],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: Color.green.opacity(0.6), radius: 20, x: 0, y: 0)
                    .shadow(color: Color.green.opacity(0.3), radius: 40, x: 0, y: 0)
                
                Text("\(batteryLevel)% Charged")
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .opacity(percentOpacity)
            }
            .scaleEffect(boltScale)
            .opacity(boltOpacity)
        }
        .onAppear {
            startAnimation()
        }
    }
    
    private func startAnimation() {
        // Phase 1: Bolt appears with spring
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6, blendDuration: 0)) {
            boltScale = 1.15
            boltOpacity = 1.0
            glowOpacity = 0.8
            glowScale = 1.0
            ringOpacity = 0.8
            ringScale = 1.0
        }
        
        // Phase 2: Settle bolt to normal size
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeInOut(duration: 0.3)) {
                boltScale = 1.0
            }
        }
        
        // Phase 3: Text appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeIn(duration: 0.3)) {
                percentOpacity = 1.0
            }
        }
        
        // Phase 4: Ring expands outward
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut(duration: 0.8)) {
                ringScale = 2.0
                ringOpacity = 0.0
            }
        }
        
        // Phase 5: Fade out everything
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeOut(duration: 0.7)) {
                boltOpacity = 0.0
                glowOpacity = 0.0
                percentOpacity = 0.0
                boltScale = 1.3
            }
        }
    }
}

// MARK: - Charging Animation Manager
@MainActor
class ChargingAnimationManager {
    static let shared = ChargingAnimationManager()
    
    private var window: NSWindow?
    private var isShowing = false
    
    func show(batteryLevel: Int = 100) {
        guard !isShowing else { return }
        isShowing = true
        
        guard let screen = NSScreen.main else {
            isShowing = false
            return
        }
        
        let contentView = NSHostingView(
            rootView: ChargingAnimationView(batteryLevel: batteryLevel)
        )
        
        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        win.isReleasedWhenClosed = false
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = contentView
        
        self.window = win
        win.orderFront(nil)
        
        // Dismiss after 2.5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.dismiss()
        }
    }
    
    private func dismiss() {
        window?.orderOut(nil)
        window = nil
        isShowing = false
    }
}
