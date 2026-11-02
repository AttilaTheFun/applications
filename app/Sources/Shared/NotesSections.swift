import ApplicationsProtocol
import MarkdownViews
import SwiftUI

/// A build's release notes as sections of the build's page: the summary
/// and any lines after it, then each of the notes' own sections ("What's
/// new", "What to test"), each section's text as Markdown (AgentUI's
/// MarkdownViews: lists, code, quotes and tables as they are written).
struct NotesSections: View {
    let notes: ReleaseNotes

    var body: some View {
        if !notes.summary.isEmpty {
            Section("Release Notes") {
                MarkdownText(notes.summary).font(.body.weight(.medium))
                if !notes.lead.isEmpty { MarkdownText(notes.lead.joined(separator: "\n")) }
            }
        }
        ForEach(Array(notes.sections.enumerated()), id: \.offset) { _, section in
            Section(section.title) {
                MarkdownText(section.lines.joined(separator: "\n"))
            }
        }
    }
}
