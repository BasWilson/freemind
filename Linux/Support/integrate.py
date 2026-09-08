"""Register a per-user Freemind installation with the desktop and shell."""
import os
from pathlib import Path
import shutil
import subprocess


def register(root):
    root = root.expanduser().resolve()
    if any(ord(character) < 32 for character in str(root)):
        raise ValueError("The installation path cannot contain control characters.")
    launcher = Path.home() / ".local/bin/freemind"
    launcher.parent.mkdir(parents=True, exist_ok=True)
    target = root / "current/launch"
    if not launcher.exists() and not launcher.is_symlink():
        launcher.symlink_to(target)
    elif not launcher.is_symlink() or launcher.resolve() != target.resolve():
        print(f"Keeping the existing {launcher}. Use {target} or the app launcher.")
    share = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
    applications = share / "applications"
    applications.mkdir(parents=True, exist_ok=True)

    def quote(value):
        # Escape both the Desktop Entry string layer and the Exec argument layer.
        value = str(value).replace("%", "%%")
        for character in ("\\", '"', "`", "$"):
            value = value.replace(character, "\\" + character)
        return '"' + value.replace("\\", "\\\\") + '"'

    def string(value):
        return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r")

    entry = (
        "[Desktop Entry]\nType=Application\nName=Freemind\n"
        "Comment=Codex, code, Git and notes in one workspace\n"
        f"Exec={quote(target)} %f\nIcon={string(root / 'current/dev.freemind.Linux.svg')}\n"
        "Terminal=false\nCategories=Development;IDE;\nStartupWMClass=dev.freemind.Linux\n"
    )
    desktop = applications / "dev.freemind.Linux.desktop"
    if desktop.is_symlink():
        raise ValueError(f"Refusing to overwrite desktop entry symlink: {desktop}")
    desktop.write_text(entry)
    if shutil.which("update-desktop-database"):
        subprocess.run(["update-desktop-database", str(applications)], capture_output=True, check=False)
    print(f"Installed. Open Freemind from your app launcher, or run {target}")
    if str(launcher.parent) not in os.environ.get("PATH", "").split(os.pathsep):
        print(f"Add {launcher.parent} to PATH to use the freemind command from your terminal.")


if __name__ == "__main__":
    import sys
    register(Path(sys.argv[1]))
