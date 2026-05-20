import SwiftUI

/// Spacing, shape, and stroke tokens from ui-spec.md §2.3.
enum ObSpacing {
    /// Horizontal padding from screen edge for chat content.
    static let screenH: CGFloat = 16

    /// Horizontal padding inside cards (citation rows, tool-call cards).
    static let cardH: CGFloat = 12

    /// Vertical rhythm between messages.
    static let messageGap: CGFloat = 16
}

enum ObRadius {
    /// Cards, citation rows.
    static let card: CGFloat = 10

    /// Input row.
    static let input: CGFloat = 12

    /// Mic / send circular buttons (32pt diameter → 16pt radius).
    static let button: CGFloat = 16

    /// Modal sheets.
    static let sheet: CGFloat = 20
}

enum ObStroke {
    /// 1px hairline border width (spec §2.3 — flat surfaces, no shadows).
    static let hairline: CGFloat = 1
}
