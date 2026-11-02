import ApplicationsProtocol
import SwiftUI

/// One build: what it is, what changed, and Install.
struct BuildView: View {
    @Environment(ApplicationsStore.self) private var store
    let id: String
    @State private var installing = false
    @State private var problem: String?
    @State private var handedOver = false

    var body: some View {
        Form {
            if let build = store.build(id), let builds = store.group(of: build) {
                Section {
                    HStack(spacing: 16) {
                        AppIconView(id: build.id, size: 64) { await store.icon(build: $0) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(build.name).font(.title2.bold())
                            HStack(spacing: 6) {
                                Text(build.versionTitle).foregroundStyle(.secondary)
                                ChannelBadge(channel: build.channel ?? .beta)
                            }
                        }
                    }
                    LabeledContent("Published") { Text(build.published, format: .relative(presentation: .named)) }
                    LabeledContent("Size", value: build.size.formatted(.byteCount(style: .file)))
                    if let installed = store.installs.installedBuild(builds) {
                        LabeledContent("Installed", value: installed.versionTitle)
                    }
                }
                Section {
                    Button {
                        installing = true
                        problem = nil
                        Task {
                            problem = await store.install(build)
                            handedOver = problem == nil
                            installing = false
                        }
                    } label: {
                        HStack {
                            Text(installing ? "Reaching the server…" : "Install \(build.name) \(build.versionTitle)")
                            if installing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(installing || store.installs.isBusy(builds))
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else if handedOver {
                        Text(DeviceInstalls.handedOverWords)
                    }
                }
                NotesSections(notes: ReleaseNotes(build.notes))
            } else {
                Section {
                    Text(store.problem ?? (store.isRefreshing ? "Asking the server…" : "This build is no longer on the server."))
                        .foregroundStyle(store.problem == nil ? Color.secondary : Color.orange)
                }
            }
        }
        .groupedPage()
        .navigationTitle(store.build(id)?.name ?? "Build")
    }
}
