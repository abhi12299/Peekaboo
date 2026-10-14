import Foundation
import MCP
import PeekabooAutomation
import TachikomaMCP

/// A window whose title names a document that `app launch` opened.
struct AppToolDocumentWindow: Equatable {
    let document: URL
    let window: ServiceWindowInfo
}

@MainActor
extension AppToolActions {
    /// Reads the app's windows once (read-only) and names the window showing each opened document, so the
    /// caller does not need `window list` to find it. A failed read finds nothing.
    func documentWindows(
        for documents: [URL],
        in app: ServiceApplicationInfo) async -> [AppToolDocumentWindow]
    {
        guard !documents.isEmpty,
              let output = try? await self.service.listWindows(
                  for: "PID:\(app.processIdentifier)",
                  timeout: nil)
        else { return [] }
        return Self.matchDocumentWindows(
            documents: documents,
            windows: output.data.windows,
            preferredWindowIDs: app.windowIDs ?? [])
    }

    /// One sentence when every window of the app is minimized, which `see` cannot capture. The window is
    /// left minimized: restoring it would change the user's screen. A failed read says nothing.
    func minimizedWindowHint(for app: ServiceApplicationInfo) async -> String? {
        guard let windows = try? await self.service.listWindows(
            for: "PID:\(app.processIdentifier)",
            timeout: nil).data.windows,
            !windows.isEmpty,
            windows.allSatisfy(\.isMinimized)
        else { return nil }
        let subject = windows.count == 1 ? "\(app.name)'s window is" : "All of \(app.name)'s windows are"
        return "\(subject) minimized; use `window restore` before `see`."
    }

    /// Matches each document's file name against window titles: an exact title (with or without the
    /// extension) beats a title that only starts with the name ("result.txt — Edited"). Windows the launch
    /// reported as new come first. Each window names at most one document.
    static func matchDocumentWindows(
        documents: [URL],
        windows: [ServiceWindowInfo],
        preferredWindowIDs: [Int]) -> [AppToolDocumentWindow]
    {
        var used = Set<Int>()
        return documents.compactMap { document in
            let ranked = windows.compactMap { window -> (window: ServiceWindowInfo, rank: Int)? in
                guard !used.contains(window.windowID),
                      let titleRank = Self.titleRank(window.title, document: document)
                else { return nil }
                let newRank = preferredWindowIDs.contains(window.windowID) ? 0 : 2
                return (window, newRank + titleRank)
            }
            guard let best = ranked.min(by: { ($0.rank, $0.window.index) < ($1.rank, $1.window.index) })
            else { return nil }
            used.insert(best.window.windowID)
            return AppToolDocumentWindow(document: document, window: best.window)
        }
    }

    /// 0 for an exact title, 1 for a title that starts with the name and then leaves it, nil otherwise.
    private static func titleRank(_ title: String, document: URL) -> Int? {
        let title = title.lowercased()
        let names = [document.lastPathComponent, document.deletingPathExtension().lastPathComponent]
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        if names.contains(title) {
            return 0
        }
        for name in names where title.hasPrefix(name) {
            let next = title[title.index(title.startIndex, offsetBy: name.count)]
            if !next.isLetter, !next.isNumber, next != "." {
                return 1
            }
        }
        return nil
    }

    /// One sentence naming the document windows, or the old `window list` hint when none was found.
    static func documentWindowHint(
        _ found: [AppToolDocumentWindow],
        documents: [URL],
        appName: String) -> String
    {
        let searchHint = "Use `window list` or `see` on \(appName) to find the new window."
        guard !found.isEmpty else { return searchHint }
        if documents.count == 1, let match = found.first {
            let id = match.window.windowID
            return "Window \(id) '\(match.window.title)' shows it; pass window_id \(id) to `see`."
        }
        let windows = found.map { match in
            "window \(match.window.windowID) '\(match.window.title)' shows \(match.document.lastPathComponent)"
        }.joined(separator: ", ")
        var hint = windows.prefix(1).uppercased() + windows.dropFirst() + "; pass its window_id to `see`."
        let missing = documents.filter { document in !found.contains { $0.document == document } }
        if !missing.isEmpty {
            hint += " No window was found for \(missing.map(\.lastPathComponent).joined(separator: ", ")); "
                + "use `window list` or `see` on \(appName)."
        }
        return hint
    }

    static func documentWindowMeta(_ found: [AppToolDocumentWindow]) -> [String: Value] {
        [
            "document_window_ids": .array(found.map { .double(Double($0.window.windowID)) }),
            "document_windows": .array(found.map { match in
                .object([
                    "path": .string(match.document.path),
                    "window_id": .double(Double(match.window.windowID)),
                    "title": .string(match.window.title),
                ])
            }),
        ]
    }
}
