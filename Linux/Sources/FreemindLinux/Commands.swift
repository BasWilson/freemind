import Foundation
import FreemindCore
import LinuxUI

struct LinuxCommand {
    let action: String, title: String, hint: String
    static let all: [LinuxCommand] = [
        .init(action: "open", title: "Open Workspace…", hint: "Ctrl+Shift+O"),
        .init(action: "quick-open", title: "Quick Open File", hint: "Ctrl+Shift+P"),
        .init(action: "codex", title: "New Codex Terminal", hint: "Ctrl+Shift+N"),
        .init(action: "shell", title: "New Shell Terminal", hint: "Ctrl+Shift+T"),
        .init(action: "configure", title: "Configure New Terminal…", hint: "Ctrl+Alt+T"),
        .init(action: "code", title: "Show Code", hint: "Ctrl+Shift+1"),
        .init(action: "git", title: "Show Git", hint: "Ctrl+Shift+2"),
        .init(action: "notes", title: "Show Notes", hint: "Ctrl+Shift+3"),
        .init(action: "files", title: "Toggle File Explorer", hint: "Ctrl+Shift+B"),
        .init(action: "sidebar-toggle", title: "Toggle Workspace Sidebar", hint: "Navigate"),
        .init(action: "next-workspace", title: "Next Workspace", hint: "Ctrl+Alt+Down"),
        .init(action: "previous-workspace", title: "Previous Workspace", hint: "Ctrl+Alt+Up"),
        .init(action: "next-pane", title: "Focus Next Terminal", hint: "Ctrl+Alt+Right"),
        .init(action: "previous-pane", title: "Focus Previous Terminal", hint: "Ctrl+Alt+Left"),
        .init(action: "maximize", title: "Maximize / Restore Terminal", hint: "Ctrl+Shift+M"),
        .init(action: "arrange", title: "Auto Arrange Terminals", hint: "Panes"),
        .init(action: "save", title: "Save File or Note", hint: "Ctrl+Shift+S"),
        .init(action: "comment", title: "Comment on Selection → Codex", hint: "Ctrl+Shift+L"),
        .init(action: "comments", title: "Workspace Comments", hint: "Code"),
        .init(action: "git-refresh", title: "Refresh Git", hint: "Git"),
        .init(action: "git-fetch", title: "Fetch All Remotes", hint: "Git"),
        .init(action: "git-commit", title: "Commit Staged Changes", hint: "Git"),
        .init(action: "git-commit-push", title: "Commit & Push", hint: "Git"),
        .init(action: "git-push", title: "Push", hint: "Git"),
        .init(action: "zoom-in", title: "Increase Terminal Font", hint: "Ctrl++"),
        .init(action: "zoom-out", title: "Decrease Terminal Font", hint: "Ctrl+−"),
        .init(action: "zoom-reset", title: "Reset Terminal Font", hint: "Ctrl+0"),
        .init(action: "settings", title: "Settings & Terminal Defaults", hint: "Ctrl+,"),
        .init(action: "update-check", title: "Check for Updates", hint: "General"),
        .init(action: "close-focused", title: "Stop & Close Focused Terminal", hint: "Ctrl+Shift+W"),
        .init(action: "quit", title: "Quit and Keep Terminals Running", hint: "Ctrl+Shift+Q"),
        .init(action: "quit-stop", title: "Quit and Stop All Terminals", hint: "General")
    ]
}
extension Controller {
    func showPalette(_ mode: String) async throws {
        if mode == "quick-open" {
            await onUI { fm_palette_begin("Quick Open File") }
            try await quickSearch("")
            await onUI { fm_palette_end() }
        } else if mode == "comments" {
            let comments = paths.flatMap { try? DurableFile.load([CodeComment].self, from: $0.comments) } ?? []
            await onUI {
                fm_palette_begin("Workspace comments")
                for comment in comments {
                    fm_palette_item(comment.comment, "\(comment.file):\(comment.startLine)–\(comment.endLine) · Open file", "file-open", comment.file)
                    fm_palette_item("Start another Codex pane", comment.comment, "comment-again", comment.id.uuidString)
                }
                fm_palette_end()
            }
        } else {
            let workspaces = workspaces, panes = layout.panes
            await onUI {
                fm_palette_begin("Commands & keyboard shortcuts")
                for command in LinuxCommand.all { fm_palette_item(command.title, command.hint, command.action, "") }
                for pane in panes {
                    fm_palette_item("Split right · " + pane.title, "Panes", "split-right", pane.id.uuidString)
                    fm_palette_item("Split below · " + pane.title, "Panes", "split-below", pane.id.uuidString)
                    fm_palette_item("Separate window · " + pane.title, "Panes", "pane-detach", pane.id.uuidString)
                }
                for path in workspaces { fm_palette_item(URL(fileURLWithPath: path).lastPathComponent, path, "workspace-select", path) }
                fm_palette_end()
            }
        }
    }
    func quickSearch(_ query: String) async throws {
        guard let paths else { return }
        let entries = WorkspaceFileListing.search(paths.root, query: query, hidden: showHidden)
        await onUI { fm_palette_clear(); for entry in entries { fm_palette_item(entry.url.lastPathComponent, paths.relative(entry.url), "file-open", entry.url.path) } }
    }
}
