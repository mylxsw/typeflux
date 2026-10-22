import Foundation

/// Time zone abbreviations people type. An abbreviation names a region, not a fixed offset:
/// "PST" in July means Los Angeles, which is then on PDT. Ambiguous ones list every region.
enum WorldClockAbbreviations {
    static let zones: [String: [String]] = [
        "PST": ["America/Los_Angeles"], "PDT": ["America/Los_Angeles"], "PT": ["America/Los_Angeles"],
        "MST": ["America/Denver"], "MDT": ["America/Denver"], "MT": ["America/Denver"],
        "CST": ["America/Chicago", "Asia/Shanghai"], "CDT": ["America/Chicago"], "CT": ["America/Chicago"],
        "EST": ["America/New_York"], "EDT": ["America/New_York"], "ET": ["America/New_York"],
        "AKST": ["America/Anchorage"], "AKDT": ["America/Anchorage"], "HST": ["Pacific/Honolulu"],
        "GMT": ["Europe/London"], "BST": ["Europe/London"], "WET": ["Europe/Lisbon"], "WEST": ["Europe/Lisbon"],
        "CET": ["Europe/Paris"], "CEST": ["Europe/Paris"], "EET": ["Europe/Athens"], "EEST": ["Europe/Athens"],
        "MSK": ["Europe/Moscow"], "IST": ["Asia/Kolkata", "Europe/Dublin", "Asia/Jerusalem"],
        "IDT": ["Asia/Jerusalem"], "GST": ["Asia/Dubai"], "PKT": ["Asia/Karachi"], "NPT": ["Asia/Kathmandu"],
        "ICT": ["Asia/Bangkok"], "WIB": ["Asia/Jakarta"], "SGT": ["Asia/Singapore"], "PHT": ["Asia/Manila"],
        "HKT": ["Asia/Hong_Kong"], "JST": ["Asia/Tokyo"], "KST": ["Asia/Seoul"],
        "AWST": ["Australia/Perth"], "ACST": ["Australia/Adelaide"], "ACDT": ["Australia/Adelaide"],
        "AEST": ["Australia/Sydney"], "AEDT": ["Australia/Sydney"], "NZST": ["Pacific/Auckland"],
        "NZDT": ["Pacific/Auckland"], "BRT": ["America/Sao_Paulo"], "ART": ["America/Argentina/Buenos_Aires"],
        "SAST": ["Africa/Johannesburg"], "EAT": ["Africa/Nairobi"], "WAT": ["Africa/Lagos"]
    ]

    /// Standard and daylight names for zones whose system abbreviation is only "GMT+8".
    private static let names: [String: (standard: String, daylight: String?)] = [
        "America/Los_Angeles": ("PST", "PDT"), "America/Vancouver": ("PST", "PDT"),
        "America/Denver": ("MST", "MDT"), "America/Phoenix": ("MST", nil), "America/Chicago": ("CST", "CDT"),
        "America/Mexico_City": ("CST", nil), "America/New_York": ("EST", "EDT"), "America/Toronto": ("EST", "EDT"),
        "America/Anchorage": ("AKST", "AKDT"), "Pacific/Honolulu": ("HST", nil),
        "Europe/London": ("GMT", "BST"), "Europe/Dublin": ("GMT", "IST"), "Europe/Lisbon": ("WET", "WEST"),
        "Europe/Paris": ("CET", "CEST"), "Europe/Berlin": ("CET", "CEST"), "Europe/Madrid": ("CET", "CEST"),
        "Europe/Rome": ("CET", "CEST"), "Europe/Amsterdam": ("CET", "CEST"), "Europe/Brussels": ("CET", "CEST"),
        "Europe/Zurich": ("CET", "CEST"), "Europe/Vienna": ("CET", "CEST"), "Europe/Stockholm": ("CET", "CEST"),
        "Europe/Oslo": ("CET", "CEST"), "Europe/Copenhagen": ("CET", "CEST"), "Europe/Warsaw": ("CET", "CEST"),
        "Europe/Prague": ("CET", "CEST"), "Europe/Budapest": ("CET", "CEST"),
        "Europe/Athens": ("EET", "EEST"), "Europe/Helsinki": ("EET", "EEST"), "Europe/Kiev": ("EET", "EEST"),
        "Europe/Moscow": ("MSK", nil), "Asia/Shanghai": ("CST", nil), "Asia/Hong_Kong": ("HKT", nil),
        "Asia/Taipei": ("CST", nil), "Asia/Tokyo": ("JST", nil), "Asia/Seoul": ("KST", nil),
        "Asia/Singapore": ("SGT", nil), "Asia/Kolkata": ("IST", nil), "Asia/Jerusalem": ("IST", "IDT"),
        "Asia/Dubai": ("GST", nil), "Asia/Karachi": ("PKT", nil), "Asia/Kathmandu": ("NPT", nil),
        "Asia/Bangkok": ("ICT", nil), "Asia/Jakarta": ("WIB", nil), "Asia/Manila": ("PHT", nil),
        "Australia/Sydney": ("AEST", "AEDT"), "Australia/Melbourne": ("AEST", "AEDT"),
        "Australia/Brisbane": ("AEST", nil), "Australia/Adelaide": ("ACST", "ACDT"), "Australia/Perth": ("AWST", nil),
        "Pacific/Auckland": ("NZST", "NZDT"), "America/Sao_Paulo": ("BRT", nil),
        "America/Argentina/Buenos_Aires": ("ART", nil), "Africa/Johannesburg": ("SAST", nil),
        "Africa/Nairobi": ("EAT", nil), "Africa/Lagos": ("WAT", nil)
    ]

    /// "BST", "EDT"; the system's own abbreviation, or "UTC+5:30", for zones not listed.
    static func abbreviation(_ zone: TimeZone, at date: Date) -> String {
        if let name = names[zone.identifier] {
            return zone.isDaylightSavingTime(for: date) ? name.daylight ?? name.standard : name.standard
        }
        if let system = zone.abbreviation(for: date), !system.hasPrefix("GMT"), !system.hasPrefix("UTC") {
            return system
        }
        return WorldClockFormat.utcOffset(seconds: zone.secondsFromGMT(for: date))
    }
}
