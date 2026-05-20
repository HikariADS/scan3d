/*
 Abstract:
 ScanPro splash / launch screen — dark mesh background, LiDAR branding, ready indicator.
 */

import SwiftUI

struct ScanProSplashView: View {
    var onFinished: () -> Void

    @State private var logoOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var statusOpacity: Double = 0
    @State private var glowPulse: Double = 0.55

    private let background = Color(red: 0.04, green: 0.04, blue: 0.05)
    private let accentBlue = Color(red: 0.63, green: 0.81, blue: 1.0)

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            MeshBackgroundPattern()
                .ignoresSafeArea()
                .opacity(0.58)

            VStack(spacing: 0) {
                Spacer()

                splashIcon
                    .opacity(logoOpacity)
                    .padding(.bottom, 28)

                Text("ScanPro")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(3)
                    .foregroundColor(.white)
                    .opacity(titleOpacity)

                Text("PRECISION SPATIAL ENGINE")
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .tracking(4.5)
                    .foregroundColor(.white.opacity(0.38))
                    .padding(.top, 10)
                    .opacity(titleOpacity)

                Spacer()

                lidarReadyPill
                    .opacity(statusOpacity)
                    .padding(.bottom, 52)

                Text("V 4.0.2  •  © 2024 SCANPRO SYSTEMS")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.2)
                    .foregroundColor(.white.opacity(0.22))
                    .padding(.bottom, 28)
                    .opacity(statusOpacity)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { runSplashSequence() }
    }

    private var splashIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.10))
                .frame(width: 112, height: 112)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: accentBlue.opacity(glowPulse * 0.35), radius: 28, y: 4)

            WireframeCubeIcon(glow: glowPulse)
                .frame(width: 56, height: 56)
                .offset(y: -8)

            Text("LiDAR")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .tracking(2.5)
                .foregroundColor(.white.opacity(0.88))
                .offset(y: 34)
        }
    }

    private var lidarReadyPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.caption.weight(.semibold))
                .foregroundColor(accentBlue)
            Text("LIDAR READY")
                .font(.system(size: 11, weight: .bold))
                .tracking(2.2)
                .foregroundColor(accentBlue)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                .background(Capsule().fill(Color.white.opacity(0.04)))
        )
    }

    private func runSplashSequence() {
        withAnimation(.easeOut(duration: 0.7)) { logoOpacity = 1 }
        withAnimation(.easeOut(duration: 0.7).delay(0.25)) { titleOpacity = 1 }
        withAnimation(.easeOut(duration: 0.6).delay(0.85)) { statusOpacity = 1 }

        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            glowPulse = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.easeInOut(duration: 0.45)) {
                onFinished()
            }
        }
    }
}

// MARK: - Mesh background

private struct MeshBackgroundPattern: View {
    private let cols = 10
    private let rows = 16

    var body: some View {
        TimelineView(.periodic(from: .distantPast, by: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                drawMesh(context: &context, size: size, time: t)
            }
        }
    }

    private func drawMesh(context: inout GraphicsContext, size: CGSize, time: Double) {
        let stepX = size.width / CGFloat(cols - 1)
        let stepY = size.height / CGFloat(rows - 1)
        var points: [CGPoint] = []

        for row in 0..<rows {
            for col in 0..<cols {
                let baseX = CGFloat(col) * stepX
                let baseY = CGFloat(row) * stepY
                let fi = Double(col) * 0.62 + Double(row) * 0.41
                let fj = Double(col) * 0.38 + Double(row) * 0.57

                // Sóng chéo + dao động riêng từng vertex — mesh “thở” như point cloud
                let waveX = sin(time * 0.85 + fi) * 10
                    + sin(time * 1.35 + fj * 1.2) * 4
                let waveY = cos(time * 0.72 + fj) * 8
                    + cos(time * 1.1 + fi * 0.9) * 5
                let drift = sin(time * 0.35 + Double(col + row) * 0.15) * 3

                points.append(CGPoint(
                    x: baseX + CGFloat(waveX + drift),
                    y: baseY + CGFloat(waveY - drift * 0.6)
                ))
            }
        }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxDist = hypot(size.width, size.height) * 0.52

        for row in 0..<rows {
            for col in 0..<cols {
                let i = row * cols + col
                let p = points[i]
                let dist = hypot(p.x - center.x, p.y - center.y)
                let fade = max(0, 1 - dist / maxDist)
                let alpha = fade * fade * 0.38
                let pulse = 0.85 + 0.15 * sin(time * 2.2 + Double(i) * 0.35)

                if col + 1 < cols {
                    strokeLine(context: &context, from: p, to: points[row * cols + col + 1],
                               alpha: alpha * pulse, width: 0.65)
                }
                if row + 1 < rows {
                    strokeLine(context: &context, from: p, to: points[(row + 1) * cols + col],
                               alpha: alpha * 0.88 * pulse, width: 0.65)
                }
                if col + 1 < cols, row + 1 < rows {
                    strokeLine(context: &context, from: p, to: points[(row + 1) * cols + col + 1],
                               alpha: alpha * 0.42 * pulse, width: 0.45)
                }

                let dotR = 1.2 + 0.9 * CGFloat(sin(time * 1.8 + Double(i) * 0.4) * 0.5 + 0.5)
                let dot = CGRect(x: p.x - dotR, y: p.y - dotR, width: dotR * 2, height: dotR * 2)
                context.fill(
                    Path(ellipseIn: dot),
                    with: .color(.white.opacity(alpha * pulse + 0.1))
                )
            }
        }
    }

    private func strokeLine(context: inout GraphicsContext, from: CGPoint, to: CGPoint,
                            alpha: Double, width: CGFloat) {
        var line = Path()
        line.move(to: from)
        line.addLine(to: to)
        context.stroke(line, with: .color(.white.opacity(alpha)), lineWidth: width)
    }
}

// MARK: - Wireframe cube

private struct WireframeCubeIcon: View {
    var glow: Double

    private let accent = Color(red: 0.63, green: 0.81, blue: 1.0)

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.45 * glow), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 34
                    )
                )
                .frame(width: 68, height: 68)

            Canvas { context, size in
                let w = size.width
                let h = size.height
                let cx = w * 0.5
                let cy = h * 0.52
                let s: CGFloat = min(w, h) * 0.30

                let front: [CGPoint] = [
                    CGPoint(x: cx - s, y: cy - s * 0.35),
                    CGPoint(x: cx + s, y: cy - s * 0.35),
                    CGPoint(x: cx + s, y: cy + s * 0.85),
                    CGPoint(x: cx - s, y: cy + s * 0.85),
                ]
                let back: [CGPoint] = front.map { CGPoint(x: $0.x + s * 0.55, y: $0.y - s * 0.55) }

                func stroke(_ pts: [CGPoint], closed: Bool) {
                    var path = Path()
                    path.move(to: pts[0])
                    for pt in pts.dropFirst() { path.addLine(to: pt) }
                    if closed { path.closeSubpath() }
                    context.stroke(path, with: .color(.white.opacity(0.92)), lineWidth: 1.4)
                }

                stroke(back, closed: true)
                stroke(front, closed: true)
                for i in 0..<4 {
                    var path = Path()
                    path.move(to: front[i])
                    path.addLine(to: back[i])
                    context.stroke(path, with: .color(.white.opacity(0.65)), lineWidth: 1.1)
                }
            }
        }
    }
}
