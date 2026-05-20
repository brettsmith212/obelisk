import SwiftUI

/// Typography tokens from ui-spec.md §2.2.
///
/// Inter is the spec'd UI face; we fall back to the system font (San Francisco)
/// until Inter is bundled. SF Mono is used for code, inline `code`, and
/// code blocks.
extension Font {
    /// 16pt body, line-height 1.45 (apply via `.lineSpacing`).
    static let obBody         = Font.system(size: 16, weight: .regular)
    static let obBodyEmphasis = Font.system(size: 16, weight: .semibold)

    /// 12pt tertiary text — timestamps, tool-call rows, meta.
    static let obMeta         = Font.system(size: 12, weight: .regular)

    /// 14pt SF Mono for inline code and code blocks.
    static let obCode         = Font.system(size: 14, weight: .regular, design: .monospaced)

    /// Top bar title.
    static let obTitle        = Font.system(size: 17, weight: .semibold)

    /// Centered "Obelisk" wordmark in the empty state.
    static let obWordmark     = Font.system(size: 34, weight: .semibold)

    /// Drawer section headers ("Today", "Yesterday", ...).
    static let obSection      = Font.system(size: 13, weight: .semibold)
}

/// Body line-height per spec (16pt × 1.45 = ~23.2pt → +7pt lineSpacing).
extension View {
    func obBodyLineSpacing() -> some View {
        self.lineSpacing(7)
    }
}
