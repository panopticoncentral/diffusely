import Foundation

/// Lenient parser for Civitai ISO 8601 timestamps.
///
/// Civitai sometimes returns timestamps with fractional seconds
/// (e.g. `2024-01-02T03:04:05.678Z`) and sometimes without
/// (e.g. `2024-01-02T03:04:05Z`). A single `ISO8601DateFormatter`
/// instance can only match one option set, so we try the fractional
/// formatter first and fall back to the plain one. Returns `nil` on
/// any failure so callers degrade gracefully rather than throwing.
private let fractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let plainFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

func parseCivitaiDate(_ string: String?) -> Date? {
    guard let string, !string.isEmpty else { return nil }
    return fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
}

/// Serializes a `Date` back to a Civitai-compatible ISO 8601 string
/// (with fractional seconds). Used when restoring persisted models
/// into API model types so the date round-trips through `publishedAtDate`.
func formatCivitaiDate(_ date: Date?) -> String? {
    guard let date else { return nil }
    return fractionalFormatter.string(from: date)
}
