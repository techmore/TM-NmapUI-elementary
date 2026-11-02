"""Checks for scripts/install-backend.sh that need no network, apt or systemd."""
import importlib.util
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/install-backend.sh"


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


deps = load("playwright-deps")
render_unit = load("render-unit")


def test_engine_is_pinned_to_a_full_commit():
    assert re.fullmatch(r"[0-9a-f]{40}\n?", (ROOT / "data/engine-revision").read_text())


def test_nothing_user_writable_runs_under_sudo():
    commands = [m.group(1) for line in SCRIPT.read_text().splitlines() if not line.lstrip().startswith("#")
                for m in re.finditer(r"\bsudo\s+(\S+)", line)]
    assert commands and set(commands) == {"apt-get"}, commands
    # Playwright only lists Chromium's libraries (as the user); apt-get installs them.
    calls = re.findall(r"playwright install-deps[^\n]*", SCRIPT.read_text())
    assert calls and all("--dry-run" in call for call in calls), calls


def run_installer(tmp_path, **env):
    # A fake `id` makes the script run as a normal user even where CI runs as root.
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    (bin_dir / "id").write_text("#!/bin/sh\necho ${FAKE_UID:-1000}\n")
    (bin_dir / "id").chmod(0o755)
    full_env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "HOME": str(tmp_path), **env}
    return subprocess.run(["bash", str(SCRIPT)], env=full_env, capture_output=True, text=True, timeout=30)


def test_refuses_to_run_as_root(tmp_path):
    result = run_installer(tmp_path, FAKE_UID="0")
    assert result.returncode == 1 and "without sudo" in result.stderr


def test_refuses_branch_names(tmp_path):
    for ref in ("main", "v2026.10.25", "41e983c"):
        result = run_installer(tmp_path, NMAPUI_REF=ref)
        assert result.returncode == 2 and "40-character" in result.stderr


def test_refuses_paths_systemd_would_split(tmp_path):
    result = run_installer(tmp_path, NMAPUI_APP_DIR=str(tmp_path / "my engine"))
    assert result.returncode == 1 and "spaces" in result.stderr


def test_unit_path_is_substituted_literally():
    template = "WorkingDirectory=@APP_DIR@\nExecStart=@APP_DIR@/.venv/bin/python -m x\n"
    out = render_unit.render(template, "/home/a|b&c/100%/app")
    assert out == "WorkingDirectory=/home/a|b&c/100%%/app\nExecStart=/home/a|b&c/100%%/app/.venv/bin/python -m x\n"
    for bad in ("relative/app", "/home/a b", '/home/a"b', "/home/a\\b", "/home/a\nb"):
        try:
            render_unit.render(template, bad)
        except ValueError:
            continue
        raise AssertionError(bad)


def test_playwright_dry_run_becomes_a_checked_package_list():
    sample = ('sudo -- sh -c "apt-get update&& apt-get install -y --no-install-recommends '
              'libasound2t64 libatk-bridge2.0-0t64 libnss3 fonts-liberation libx11-xcb1"\n')
    assert deps.packages(sample) == ["libasound2t64", "libatk-bridge2.0-0t64", "libnss3",
                                     "fonts-liberation", "libx11-xcb1"]
    assert deps.packages('sh -c "apt-get update && apt-get install -y --no-install-recommends libnss3"') == ["libnss3"]
    assert deps.packages("nothing to do\n") == []
    for hostile in ('apt-get install -y libnss3 $(touch /tmp/x)', "apt-get install -y Libnss3",
                    "apt-get install -y lib*"):
        try:
            deps.packages(hostile)
        except ValueError:
            continue
        raise AssertionError(hostile)
