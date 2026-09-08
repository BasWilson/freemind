#!/usr/bin/env python3
"""Generate a single Bash installer with a pinned release and Ed25519 public key."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def build(output, environment):
    spec = importlib.util.spec_from_file_location("update", ROOT / "Linux/Support/update.py")
    update = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(update)
    config = dict(schemaVersion=1, version=environment["FREEMIND_RELEASE_VERSION"],
                  repository=environment["FREEMIND_UPDATE_REPOSITORY"], publicKey=environment["LINUX_PUBLIC_ED_KEY"],
                  architecture=update.architecture())
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary)
        (folder / "release.json").write_text(json.dumps(config))
        update.configuration(folder)
    script = '''#!/usr/bin/env bash
# Freemind: signed Linux installer. Source: Scripts/build-linux-installer.py
set -euo pipefail
command -v python3 >/dev/null || { echo 'Install Python 3.11+ with your package manager, then rerun this installer.' >&2; exit 1; }
python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' || { echo 'Python 3.11+ is required.' >&2; exit 1; }
python3 - "$@" <<'FREEMIND_INSTALLER_PY'
import sys
import types
'''
    for name, path in (("freemind_update", "Linux/Support/update.py"), ("freemind_integrate", "Linux/Support/integrate.py"), ("freemind_bootstrap", "Scripts/linux-bootstrap.py")):
        source = (ROOT / path).read_text()
        # Keep the published script readable in less, including the verifier and
        # its pinned key. Fall back to repr if a future source uses this delimiter.
        literal = "r'''\n" + source + "'''" if "'''" not in source else repr(source)
        script += f"\n# Embedded source: {path}\n"
        script += f"module = types.ModuleType({name!r})\nsys.modules[{name!r}] = module\n"
        script += f"exec(compile({literal}, {path!r}, 'exec'), module.__dict__)\n"
    script += f"raise SystemExit(module.main({config!r}))\nFREEMIND_INSTALLER_PY\n"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(script)
    output.chmod(0o755)
    return output


if __name__ == "__main__":
    print(build(Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "dist/install.sh", os.environ))
