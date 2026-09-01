import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Design tokens: warm paper surface, floating white cards (shadow, no
/// borders), one product blue, tinted status hues that double as movement
/// cues (a move chip wears its destination's tint). Light-palette by design.
enum Theme {
    static let blue = Color(hex: 0x2B5FD9)
    static let blueDark = Color(hex: 0x1D48B8)
    static let blueTint = Color(hex: 0xE8EEFB)
    static let blueWash = Color(hex: 0xF5F8FE)

    static let ink = Color(hex: 0x1D2433)
    static let inkMid = Color(hex: 0x44546F)
    static let inkSecondary = Color(hex: 0x5C6675)
    static let inkTertiary = Color(hex: 0x8993A4)

    static let surface = Color(hex: 0xF4F3F0)
    static let card = Color.white
    static let border = Color(hex: 0xE7E6E2)
    static let borderStrong = Color(hex: 0xCBCFD8)
    static let divider = Color(hex: 0xEEF0F3)
    static let lozengeGray = Color(hex: 0xE4E4E1)

    static let greenText = Color(hex: 0x1F7A45)
    static let greenTint = Color(hex: 0xE3F2E9)
    static let amber = Color(hex: 0xB26B00)
    static let amberTint = Color(hex: 0xFDF0DC)
    static let amberBorder = Color(hex: 0xF2DBB4)
    static let amberDeep = Color(hex: 0x6E4A00)
    static let red = Color(hex: 0xC9372C)

    static let cardShadow = Color(hex: 0x172B4D).opacity(0.07)

    static func lozenge(for status: TaskStatus) -> (bg: Color, fg: Color) {
        switch status {
        case .todo: return (lozengeGray, inkMid)
        case .inProgress: return (blueTint, blueDark)
        case .done: return (greenTint, greenText)
        }
    }
}

/// Uppercase tinted status chip (the design's lozenge).
struct Lozenge: View {
    let text: String
    let bg: Color
    let fg: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .kerning(0.6)
            .foregroundStyle(fg)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(bg, in: Capsule())
    }
}

/// White floating card: 16pt continuous radius, soft ambient shadow, no border.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Theme.cardShadow, radius: 8, y: 3)
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardBackground()) }
}

/// Buttons that feel like buttons: a slight shrink while the finger is down.
struct PressedScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The design's section caption: 12pt bold, letterspaced, uppercase.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .kerning(0.7)
            .foregroundStyle(Theme.inkSecondary)
    }
}
