import SwiftUI

extension ReviewColor {
    var swatch: Color {
        switch self {
        case .blue: .blue
        case .teal: .teal
        case .green: .green
        case .yellow: .yellow
        case .orange: .orange
        case .red: .red
        case .pink: .pink
        case .purple: .purple
        case .gray: .gray
        default: customSwatch
        }
    }

    private var customSwatch: Color {
        guard rawValue.hasPrefix("#"), let hex = UInt32(rawValue.dropFirst(), radix: 16) else { return .blue }
        return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }

    var menuImage: NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            NSColor(self.swatch).setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 12, height: 12)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct ReviewColorPicker: View {
    @Binding var color: ReviewColor?
    let label: String
    var inheritedColor: ReviewColor = .blue
    var resetTitle = "Use inherited color"
    var allowsInheritance = true
    var unavailableColors: Set<ReviewColor> = []

    private var choices: [ReviewColor] {
        if let color, !ReviewColor.allCases.contains(color) { return [color] + ReviewColor.allCases }
        return ReviewColor.allCases
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill((color ?? inheritedColor).swatch).frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                .accessibilityHidden(true)
            Menu {
                if allowsInheritance {
                    Button { color = nil } label: {
                        Label { Text(resetTitle + (color == nil ? " ✓" : "")) }
                        icon: { Image(nsImage: inheritedColor.menuImage) }
                    }
                    Divider()
                } else {
                    Button("Choose unused color") {
                        color = .nextUnused(excluding: unavailableColors.union(color.map { [$0] } ?? []))
                    }
                    Divider()
                }
                ForEach(choices) { choice in
                    Button { color = choice } label: {
                        Label {
                            Text(choice.name + (color == choice ? " ✓" : ""))
                        } icon: {
                            Image(nsImage: choice.menuImage)
                        }
                    }
                    .disabled(unavailableColors.contains(choice) && color != choice)
                }
            } label: {
                Text(color?.name ?? (resetTitle == "Default blue" ? "Default" : resetTitle == "Use neutral color" ? "Neutral" : "Inherited"))
                    .font(.caption).foregroundStyle(.primary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize().controlSize(.small)
            .accessibilityLabel(label)
            .accessibilityValue(color?.name ?? resetTitle)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        .fixedSize()
        .help("\(label): \(color?.name ?? resetTitle)")
    }
}
