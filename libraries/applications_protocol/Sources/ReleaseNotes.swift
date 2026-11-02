import Foundation

/// A build's release notes, as agents write them: a first line that says
/// the change (the push's text), then Markdown sections — "## What's new",
/// "## What to test" — each a few lines or bullets.
///
///     Dictation in the composer; attachments open in Quick Look.
///
///     ## What's new
///     - The microphone in the composer dictates into the draft.
///
///     ## What to test
///     - Dictate a message, edit it, send it.
public struct ReleaseNotes: Sendable, Equatable {
    /// The first line that is not a heading, without list marks.
    public var summary: String
    /// The text before the first heading, after the summary.
    public var lead: [String]
    /// Each "#"/"##" heading with its lines, in order.
    public var sections: [Section]

    public struct Section: Sendable, Equatable {
        public var title: String
        public var lines: [String]
    }

    public init(_ text: String) {
        var summary = ""
        var lead: [String] = []
        var sections: [Section] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                sections.append(Section(title: title, lines: []))
            } else if line.isEmpty {
                continue
            } else if summary.isEmpty && sections.isEmpty {
                summary = Self.unmarked(line)
            } else if sections.isEmpty {
                lead.append(line)
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }
        if summary.isEmpty, let first = sections.first?.lines.first { summary = Self.unmarked(first) }
        self.summary = summary
        self.lead = lead
        self.sections = sections.filter { !$0.lines.isEmpty }
    }

    /// A line without the list mark in front of it.
    public static func unmarked(_ line: String) -> String {
        for mark in ["- ", "* ", "• "] where line.hasPrefix(mark) { return String(line.dropFirst(mark.count)) }
        return line
    }
}
