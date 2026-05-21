import Foundation

/// Shared formatting helpers used by the Phase B read tools. Kept out
/// of `VaultIndex` because formatting is a tool-layer concern (the
/// index returns native `Date`s; the tools shape them for the model).
enum VaultToolFormatting {
    /// ISO-8601 string with internet-date-time fractional precision.
    /// Stable across locales and time zones, which is what the model
    /// wants when reasoning about "what did I touch in the last 3 days".
    static func iso(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
