import SwiftUI

/// Color tokens from ui-spec.md §2.1.
///
/// Dark mode is primary; light mode is a faithful adaptation. Each token
/// resolves to the correct hex per the current trait collection.
///
/// Usage: `Color.obBackground`, `Color.obAccent`, etc.
extension Color {
    // MARK: - Surfaces

    static let obBackground = Color(
        light: Color(hex: 0xFAFAFA),
        dark:  Color(hex: 0x1E1E1E)
    )

    /// Cards and the input row.
    static let obSurface = Color(
        light: Color(hex: 0xFFFFFF),
        dark:  Color(hex: 0x262626)
    )

    /// Drawer and modals.
    static let obSurfaceElevated = Color(
        light: Color(hex: 0xFFFFFF),
        dark:  Color(hex: 0x2A2A2A)
    )

    /// 1px hairline borders.
    static let obBorder = Color(
        light: Color(hex: 0xE5E5E5),
        dark:  Color(hex: 0x333333)
    )

    // MARK: - Text

    static let obTextPrimary = Color(
        light: Color(hex: 0x1A1A1A),
        dark:  Color(hex: 0xECECEC)
    )

    static let obTextSecondary = Color(
        light: Color(hex: 0x6B6B6B),
        dark:  Color(hex: 0xA0A0A0)
    )

    /// Tool calls, timestamps, meta.
    static let obTextTertiary = Color(
        light: Color(hex: 0x9A9A9A),
        dark:  Color(hex: 0x6E6E6E)
    )

    // MARK: - Accent + status

    static let obAccent = Color(
        light: Color(hex: 0x7C3AED),
        dark:  Color(hex: 0xA78BFA)
    )

    static let obStatusAmber = Color(
        light: Color(hex: 0xD97706),
        dark:  Color(hex: 0xF59E0B)
    )

    static let obStatusRed = Color(
        light: Color(hex: 0xDC2626),
        dark:  Color(hex: 0xF87171)
    )

    static let obStatusGreen = Color(
        light: Color(hex: 0x059669),
        dark:  Color(hex: 0x34D399)
    )
}

// MARK: - Private helpers

private extension Color {
    /// Build a Color from a 24-bit hex literal: `Color(hex: 0xA78BFA)`.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }

    /// Build a color that resolves differently in light vs dark mode.
    init(light: Color, dark: Color) {
        self = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
    }
}
