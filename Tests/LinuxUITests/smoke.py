"""Real Wayland/GTK lifecycle check; requires PyGObject and the session D-Bus.

Uses the app's native GActions with isolated shell panes, never a live Codex
conversation or an existing workspace. Run via Scripts/test-linux-ui.sh.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from gi.repository import Gio, GLib


def wait_for(check, description, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError(f"Timed out: {description}")


def run():
    executable = str(Path(sys.argv[1]).resolve())
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    process = None
    with tempfile.TemporaryDirectory(prefix="freemind-ui-test-") as temporary:
        root = Path(temporary) / "workspace"
        root.mkdir()
        socket = f"/tmp/freemind-{os.getuid()}/{hashlib.sha256(str(root).encode()).hexdigest()[:20]}.sock"
        environment = dict(os.environ, GDK_BACKEND="wayland", SHELL="/bin/sh", XDG_STATE_HOME=temporary + "/state", XDG_CONFIG_HOME=temporary + "/config")
        log_path = Path(".build-support/linux-ui-smoke.log")
        log_path.parent.mkdir(exist_ok=True)

        def tmux(*args, check=True):
            return subprocess.run(["tmux", "-S", socket, *args], text=True, capture_output=True, check=check).stdout

        def layout():
            try:
                return json.loads((root / ".freemind/layout.json").read_text())["panes"]
            except (OSError, ValueError):
                return []

        def connection():
            names = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames", None, None, 0, 2000, None).unpack()[0]
            for name in names:
                if not name.startswith(":"):
                    continue
                try:
                    pid = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID", GLib.Variant("(s)", (name,)), None, 0, 2000, None).unpack()[0]
                    if pid == process.pid:
                        return name
                except GLib.Error:
                    pass
            return None

        def action(name, argument=None):
            parameters = [] if argument is None else [GLib.Variant("s", argument)]
            bus.call_sync(destination, "/dev/freemind/Linux", "org.gtk.Actions", "Activate", GLib.Variant("(sava{sv})", (name, parameters, {})), None, 0, 3000, None)

        def snapshots():
            return tmux("list-panes", "-a", "-F", "#{session_name}\t#{pane_pid}\t#{pane_dead}", check=False).splitlines()

        with log_path.open("w") as log:
            try:
                process = subprocess.Popen([executable, str(root)], env=environment, stdout=log, stderr=log)
                destination = wait_for(connection, "app D-Bus registration")
                wait_for(lambda: (root / ".freemind/workspace.json").exists(), "workspace opened")
                action("shell"); action("shell")
                wait_for(lambda: len(layout()) == 2 and len(snapshots()) == 2, "two shell panes")
                wait_for(lambda: len(tmux("list-clients", "-F", "#{client_pid}").splitlines()) == 2, "two VTE attachment clients")
                original = sorted(snapshots())
                clients = sorted(tmux("list-clients", "-F", "#{client_pid}").splitlines())
                first = layout()[0]["id"]
                session = "fm-" + first
                tmux("send-keys", "-t", session, "-l", "export FM_UI_VALUE=alive; printf 'PORT_%s_🙂\\n' ready")
                tmux("send-keys", "-t", session, "Enter")
                wait_for(lambda: "PORT_ready_🙂" in tmux("capture-pane", "-p", "-t", session), "Unicode terminal output")
                tmux("send-keys", "-t", session, "-l", "printf 'STATE_%s\\n' \"$FM_UI_VALUE\"")
                action("right", first)
                wait_for(lambda: layout()[-1]["id"] == first, "pane reordered")
                assert sorted(tmux("list-clients", "-F", "#{client_pid}").splitlines()) == clients, "Reorder replaced VTE clients"
                # Settings update live panes without replacing their clients.
                action("settings")
                action("setting", "appearance\ndark")
                action("setting", "theme\nbuiltin:ocean")
                action("setting", "terminalTheme\nbuiltin:dracula")
                config = Path(temporary) / "config/freemind/settings.json"
                wait_for(lambda: config.exists() and json.loads(config.read_text()).get("terminalTheme") == "dracula", "independent appearance settings saved")
                assert sorted(tmux("list-clients", "-F", "#{client_pid}").splitlines()) == clients, "Theme change replaced VTE clients"
                action("setting", "options.model\nui-test-model")
                action("defaults-save")
                wait_for(lambda: json.loads(config.read_text())["workspaceDefaults"]["model"] == "ui-test-model", "global defaults saved")
                # File tree/editor, crash drafts and external-edit protection.
                source = root / "Sources"; source.mkdir()
                code = source / "hello.swift"; code.write_text('let greeting = "hello"\n')
                action("file-expand", str(source))
                action("file-open", str(code))
                time.sleep(0.3)
                action("edit", 'code\nlet greeting = "edited"\n')
                draft = root / ".freemind/local/code-draft.json"
                wait_for(draft.exists, "unsaved code checkpointed")
                code.write_text("external edit\n")
                action("save-document", "code")
                time.sleep(0.3)
                assert code.read_text() == "external edit\n", "Editor overwrote an external change"
                copy = source / "copy.swift"
                action("save-copy-to", "code\n" + str(copy))
                wait_for(copy.exists, "conflicting edit saved as a copy")
                assert "edited" in copy.read_text()
                # Restore the expected baseline, then save the user's draft.
                code.write_text('let greeting = "hello"\n')
                action("save-document", "code")
                wait_for(lambda: "edited" in code.read_text(), "code saved after conflict resolved")
                action("notes")
                action("note-create", "Port notes")
                note = root / ".freemind/notes/Port notes.md"
                wait_for(note.exists, "new Markdown note")
                action("edit", "notes\n# Port notes\n\nAutosaved **Markdown**.\n")
                wait_for(lambda: "Autosaved" in note.read_text(), "notes autosave")
                action("notes-preview")
                # Two workspaces remain open and keep their own metadata.
                second = Path(temporary) / "another workspace"; second.mkdir()
                def git(*args):
                    return subprocess.run(["git", "-C", str(second), *args], capture_output=True, text=True, check=True).stdout
                git("init", "-b", "main")
                git("config", "user.name", "Freemind UI Test"); git("config", "user.email", "test@example.invalid")
                (second / "tracked.txt").write_text("original\n")
                git("add", "tracked.txt"); git("commit", "-m", "Initial")
                git("branch", "feature")
                action("workspace-select", str(second))
                wait_for(lambda: (second / ".freemind/workspace.json").exists(), "second workspace opened")
                assert json.loads((second / ".freemind/workspace.json").read_text())["defaults"]["model"] == "ui-test-model"
                registry = Path(temporary) / "state/freemind/linux.json"
                wait_for(lambda: len(json.loads(registry.read_text())["workspaces"]) == 2, "both workspaces retained in sidebar")
                assert sorted(snapshots()) == original, "Workspace switch stopped shells"
                action("git")
                (second / "tracked.txt").write_text("changed\n")
                action("git-refresh")
                time.sleep(0.4)
                action("git-stage", "")
                wait_for(lambda: "tracked.txt" in git("diff", "--cached", "--name-only"), "Git stage")
                action("commit-draft", "UI commit")
                action("git-commit")
                wait_for(lambda: git("log", "-1", "--format=%s").strip() == "UI commit", "Git commit")
                action("git-diff-mode")
                action("git-switch", "refs/heads/feature")
                wait_for(lambda: git("branch", "--show-current").strip() == "feature", "branch switch")
                action("workspace-select", str(root))
                wait_for(lambda: len(tmux("list-clients", "-F", "#{client_pid}", check=False).splitlines()) == 2, "original workspace reattached")
                assert sorted(snapshots()) == original
                # Resizable sidebars and a detached terminal keep their state.
                action("sidebar-width", "280")
                action("view-state", "fileBrowserWidth\n260")
                # Exercise manual splits with shell panes and no Codex prompt.
                saved_layout = root / ".freemind/layout.json"
                tree = json.loads(saved_layout.read_text())
                tree["automatic"] = False
                saved_layout.write_text(json.dumps(tree))
                action("workspace-select", str(root))
                wait_for(lambda: len(tmux("list-clients", "-F", "#{client_pid}", check=False).splitlines()) == 2, "manual split terminals")
                time.sleep(0.4)
                clients_before_detach = sorted(tmux("list-clients", "-F", "#{client_pid}").splitlines())
                split_id = tree["tree"]["split"]["id"]
                action("pane-ratio", split_id + "\n0.65")
                wait_for(lambda: abs(json.loads(saved_layout.read_text())["tree"]["split"]["ratio"] - 0.65) < 0.001, "manual split ratio persisted")
                action("pane-detach", first)
                time.sleep(0.4)
                assert sorted(snapshots()) == original, "Detaching changed shell processes"
                assert sorted(tmux("list-clients", "-F", "#{client_pid}").splitlines()) == clients_before_detach, "Detaching replaced VTE clients"
                action("pane-detach", first)
                action("arrange")
                action("code")
                action("file-close")
                action("quit")
                assert process.wait(timeout=10) == 0
                assert sorted(snapshots()) == original, "Quit changed shell processes"
                process = subprocess.Popen([executable, str(root)], env=environment, stdout=log, stderr=log)
                destination = wait_for(connection, "reopened app")
                wait_for(lambda: len(tmux("list-clients", "-F", "#{client_pid}").splitlines()) == 2, "reattached VTE clients")
                assert sorted(snapshots()) == original, "Reopen replaced shell processes"
                assert json.loads(config.read_text())["theme"] == "ocean"
                assert len(json.loads(registry.read_text())["workspaces"]) == 2
                assert json.loads(registry.read_text())["sidebarWidth"] == 280
                tmux("send-keys", "-t", session, "Enter")
                wait_for(lambda: "STATE_alive" in tmux("capture-pane", "-p", "-t", session), "unsent input and shell state retained")
                action("close", first)
                wait_for(lambda: len(layout()) == 1 and len(snapshots()) == 1, "explicit close stops one session")
                action("quit")
                assert process.wait(timeout=10) == 0
            finally:
                if process and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
                tmux("kill-server", check=False)
        output = log_path.read_text()
        assert "CRITICAL" not in output and "Gtk-WARNING" not in output, output
    print("PASS: native GTK/VTE lifecycle, settings and defaults, multiple workspaces, file editing/conflict protection, notes autosave, sidebar restoration, detached panes, Unicode, reorder, persistent shells and unsent input, explicit close, clean GTK log.")


if __name__ == "__main__":
    run()
