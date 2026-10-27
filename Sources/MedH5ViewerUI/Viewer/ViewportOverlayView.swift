import SwiftUI
import MedH5Kit

/// The text drawn over a viewport: title, corner text, orientation letters,
/// point and box labels, classification badges, notes about layers not
/// drawn, and progress while volumes load.
struct SliceViewportOverlay: View {
    let presentation: ViewportPresentation

    private let font = Font.system(size: 11, weight: .medium).monospacedDigit()

    private var showsLetters: Bool { presentation.showsOrientation && presentation.orientation != nil }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                labels
                if showsLetters, let o = presentation.orientation {
                    orientationLetters(o, size: geo.size)
                }
                corners(width: geo.size.width)
                if presentation.isActive {
                    Rectangle()
                        .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 2)
                }
                if let placeholder = presentation.placeholder {
                    Text(placeholder)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !presentation.loading.isEmpty {
                    LoadingBadge(items: presentation.loading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .allowsHitTesting(false)
        .environment(\.colorScheme, .dark)
    }

    /// The four corners' text. Each side keeps to its half of the view, clear
    /// of the orientation letter in the middle of the edge: a narrow view
    /// cuts long lines short rather than writing them over the letter.
    private func corners(width: CGFloat) -> some View {
        let gap: CGFloat = showsLetters ? 40 : 12
        let side = max(40, (width - 20 - gap) / 2)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(presentation.titleColor).frame(width: 7, height: 7)
                        Text(presentation.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    }
                    .padding(.bottom, 1)
                    ForEach(Array(presentation.topLeft.enumerated()), id: \.offset) { _, line in
                        Text(line).font(font).foregroundStyle(.white.opacity(0.78)).lineLimit(1)
                    }
                }
                .frame(maxWidth: side, alignment: .leading)
                Spacer(minLength: gap)
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(Array(presentation.topRight.enumerated()), id: \.offset) { _, line in
                        Text(line).font(font).foregroundStyle(.white.opacity(0.78)).lineLimit(1)
                    }
                }
                .frame(maxWidth: side, alignment: .trailing)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(presentation.badges, id: \.self) { badge in
                        Label(badge, systemImage: "tag.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.85)))
                    }
                    ForEach(Array(presentation.bottomLeft.enumerated()), id: \.offset) { _, line in
                        Text(line).font(font).foregroundStyle(.white.opacity(0.78)).lineLimit(1)
                    }
                }
                .frame(maxWidth: side, alignment: .leading)
                Spacer(minLength: gap)
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(Array(presentation.notes.prefix(4).enumerated()), id: \.offset) { _, note in
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color(red: 1, green: 0.78, blue: 0.35))
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 420, alignment: .trailing)
                    }
                    ForEach(Array(presentation.bottomRight.enumerated()), id: \.offset) { _, line in
                        Text(line).font(font).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    if !presentation.hint.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            ForEach(presentation.hint, id: \.self) { hint in
                                Text(hint).font(font).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                            Color.clear.frame(width: 0, height: 0)
                        }
                    }
                }
                .frame(maxWidth: side, alignment: .trailing)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.9), radius: 1.5, x: 0, y: 0.5)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func orientationLetters(_ o: OrientationLetters, size: CGSize) -> some View {
        let style = Font.system(size: 13, weight: .semibold, design: .rounded)
        let color = Color(red: 1, green: 0.86, blue: 0.45).opacity(0.92)
        return ZStack {
            Text(o.top).position(x: size.width / 2, y: 14)
            Text(o.bottom).position(x: size.width / 2, y: size.height - 14)
            Text(o.left).position(x: 14, y: size.height / 2)
            Text(o.right).position(x: size.width - 14, y: size.height / 2)
        }
        .font(style)
        .foregroundStyle(color)
        .shadow(color: .black.opacity(0.9), radius: 1.5)
    }

    private var labels: some View {
        ZStack(alignment: .topLeading) {
            ForEach(presentation.labels) { label in
                let c = label.color
                let light = 0.299 * Double(c.r) + 0.587 * Double(c.g) + 0.114 * Double(c.b) > 150
                Text(label.text)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(light ? Color.black.opacity(0.85) : Color.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(c.withAlpha(255).color.opacity(0.88)))
                    .fixedSize()
                    .opacity(label.opacity)
                    .offset(x: label.position.x, y: label.position.y - 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Progress of the volumes a viewport is waiting for.
struct LoadingBadge: View {
    let items: [LoadingItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items.prefix(3)) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if let p = item.progress {
                        ProgressView(value: min(1, max(0, p))).progressViewStyle(.linear).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
            }
        }
        .frame(width: 220)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1)))
        .foregroundStyle(.white)
    }
}
