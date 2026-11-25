#if canImport(UIKit)
import NoteKit
import SwiftUI

@main
struct NoteMainApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .tint(NoteTheme.accent)
                .onOpenURL { url in
                    // "Note에서 열기" from Files, Mail, Safari…: PDFs are saved on this iPad and open as PDFs.
                    guard url.isFileURL else { return }
                    if url.pathExtension.lowercased() == "pdf" {
                        app.openIncomingPDF(url, into: LibraryLocation(source: .local, folder: "/"))
                    } else if url.pathExtension.lowercased() == FileNaming.notebookExtension {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        app.perform(.local) { lib in
                            let path = try lib.importFile(from: url, into: "/")
                            app.openNotebook(LibraryRef(source: .local, path: path))
                        }
                    }
                }
        }
    }
}
#endif
