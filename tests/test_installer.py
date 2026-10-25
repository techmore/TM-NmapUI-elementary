"""Run installer transactions in private homes with fake package/service/runtime commands.

Git checkout, unit rendering, release staging and rollback files are real. No host
systemd, sudo, downloads, Python packages, browser install or scans are invoked.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


def command(path, body):
    path.write_text('#!/bin/bash\nset -e\n' + body)
    path.chmod(0o755)


@pytest.fixture
def sandbox(tmp_path):
    home = tmp_path / 'private home % & space'
    home.mkdir()
    fake = tmp_path / 'bin'
    fake.mkdir()
    source = tmp_path / 'source checkout'
    source.mkdir()
    subprocess.run(['git', 'init', '-q', str(source)], check=True)
    (source / 'requirements.txt').write_text('# isolated fixture\n')
    (source / 'engine.py').write_text('VERSION = 1\n')
    def commit():
        subprocess.run(['git', '-C', str(source), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(source), '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                        'commit', '-qm', 'fixture'], check=True)
        return subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    ref = commit()
    command(fake / 'id', 'echo 1000\n')
    command(fake / 'dpkg', 'exit 0\n')
    command(fake / 'sudo', 'printf "sudo %s\\n" "$*" >> "$CALLS"\n"$@"\n')
    command(fake / 'sleep', 'exit 0\n')
    command(fake / 'python3', '''if [[ $1 == -m && $2 == venv ]]; then
  mkdir -p "$3/bin"
  printf '#!/bin/bash\\nexit 0\\n' > "$3/bin/python"
  chmod +x "$3/bin/python"
else
  exec "$REAL_PYTHON" "$@"
fi
''')
    command(fake / 'systemctl', '''printf 'systemctl %s\\n' "$*" >> "$CALLS"
if [[ $1 != --user ]]; then [[ ${SYSTEM_ACTIVE:-0} == 1 ]]; exit; fi
case $2 in
  is-active) [[ -f "$HOME/active" ]];;
  is-enabled) [[ -f "$HOME/enabled" ]];;
  enable) touch "$HOME/enabled";;
  restart) [[ ${FAIL_RESTART:-0} != 1 ]] || exit 1; touch "$HOME/active";;
  stop) rm -f "$HOME/active";;
  disable) rm -f "$HOME/enabled" "$HOME/active";;
esac
''')
    command(fake / 'curl', '''if [[ $* == *health/live* ]]; then [[ ${PORT_OCCUPIED:-0} == 1 ]]; exit; fi
[[ -f "$HOME/active" ]] || exit 7
[[ ${FAIL_READY:-0} != 1 ]] || { printf '{"ready":false}'; exit; }
printf '{"ready":true}'
''')
    env = {**os.environ, 'HOME': str(home), 'PATH': str(fake) + os.pathsep + os.environ['PATH'],
           'NMAPUI_REF': ref, 'NMAPUI_APP_DIR': str(source), 'REAL_PYTHON': sys.executable,
           'CALLS': str(tmp_path / 'calls')}
    return home, source, ref, commit, env


def run_install(env, *args):
    return subprocess.run(['bash', str(ROOT / 'scripts/install-backend.sh'), *args], env=env,
                          capture_output=True, text=True, timeout=15)


def test_requires_immutable_ref_before_any_install(sandbox):
    home, source, ref, commit, env = sandbox
    result = run_install({**env, 'NMAPUI_REF': 'main'})
    assert result.returncode == 2
    assert not (home / '.local/share/nmapui/releases').exists()


@pytest.mark.parametrize('conflict', ['custom_unit', 'system', 'port'])
def test_refuses_existing_service_ownership_conflicts(sandbox, conflict):
    home, source, ref, commit, env = sandbox
    unit = home / '.config/systemd/user/nmapui.service'
    if conflict == 'custom_unit':
        unit.parent.mkdir(parents=True)
        unit.write_text('custom service, keep me\n')
    else:
        env['SYSTEM_ACTIVE' if conflict == 'system' else 'PORT_OCCUPIED'] = '1'
    result = run_install(env)
    assert result.returncode != 0
    if conflict == 'custom_unit':
        assert unit.read_text() == 'custom service, keep me\n'
    assert not (home / '.local/share/nmapui/releases').exists()
    calls = Path(env['CALLS']).read_text() if Path(env['CALLS']).exists() else ""
    assert 'sudo' not in calls
    assert 'restart' not in calls


def test_release_update_rollback_and_uninstall_preserve_data(sandbox):
    home, source, ref, commit, env = sandbox
    original_head = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True)
    result = run_install(env)
    assert result.returncode == 0, result.stderr
    base = home / '.local/share/nmapui'
    data = base / 'private-scan.json'
    data.write_text('preserve scan data')
    unit = home / '.config/systemd/user/nmapui.service'
    first_unit = unit.read_text()
    release = base / 'releases' / ref
    assert json.loads((release / '.nmapui-release.json').read_text())['engine_commit'] == ref
    assert f'WorkingDirectory="{str(release).replace("%", "%%")}"' in first_unit
    assert 'ExecStart="' in first_unit
    assert (unit.stat().st_mode & 0o777) == 0o600
    assert subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True) == original_head
    (source / 'engine.py').write_text('VERSION = 2\n')
    second = commit()
    # Local source checkout remains dirty and attached; installer clones committed content only.
    (source / 'engine.py').write_text('uncommitted work, preserve it\n')
    result = run_install({**env, 'NMAPUI_REF': second})
    assert result.returncode == 0, result.stderr
    assert second in unit.read_text()
    assert (source / 'engine.py').read_text() == 'uncommitted work, preserve it\n'
    assert (base / 'previous.service').read_text() == first_unit
    result = run_install(env, '--rollback')
    assert result.returncode == 0, result.stderr
    assert unit.read_text() == first_unit
    result = subprocess.run(['bash', str(ROOT / 'scripts/uninstall-backend.sh')], env=env,
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert not unit.exists()
    assert data.read_text() == 'preserve scan data'
    assert release.exists() and (base / 'releases' / second).exists()
    assert 'disable --now nmapui-dev.service' not in Path(env['CALLS']).read_text()


@pytest.mark.parametrize('failure', ['FAIL_READY', 'FAIL_RESTART'])
def test_failed_candidate_restores_existing_unit_and_data(sandbox, failure):
    home, source, ref, commit, env = sandbox
    result = run_install(env)
    assert result.returncode == 0, result.stderr
    unit = home / '.config/systemd/user/nmapui.service'
    first_unit = unit.read_text()
    (source / 'engine.py').write_text('VERSION = 2\n')
    second = commit()
    result = run_install({**env, 'NMAPUI_REF': second, failure: '1'})
    assert result.returncode != 0
    assert unit.read_text() == first_unit
    assert (home / 'enabled').exists()
    assert (home / '.local/share/nmapui/releases' / ref).exists()


def test_uninstall_refuses_custom_unit(sandbox):
    home, source, ref, commit, env = sandbox
    unit = home / '.config/systemd/user/nmapui.service'
    unit.parent.mkdir(parents=True)
    unit.write_text('custom\n')
    result = subprocess.run(['bash', str(ROOT / 'scripts/uninstall-backend.sh')], env=env,
                            capture_output=True, text=True, timeout=10)
    assert result.returncode != 0
    assert unit.read_text() == 'custom\n'


def test_first_failed_install_removes_unit_but_keeps_staged_release(sandbox):
    home, source, ref, commit, env = sandbox
    result = run_install({**env, 'FAIL_READY': '1'})
    assert result.returncode != 0
    assert not (home / '.config/systemd/user/nmapui.service').exists()
    assert not (home / 'active').exists()
    assert not (home / 'enabled').exists()
    assert (home / '.local/share/nmapui/releases' / ref).exists()


def test_native_uninstall_preserves_profile_and_unrelated_assets(sandbox):
    home, source, ref, commit, env = sandbox
    binary = home / '.local/bin/io.github.techmore.NmapUI'
    binary.parent.mkdir(parents=True)
    binary.write_text('native app')
    other = binary.with_name('other-app')
    other.write_text('preserve')
    profile = home / '.local/share/nmapui-elementary/cookies.sqlite'
    profile.parent.mkdir(parents=True)
    profile.write_text('private profile')
    result = subprocess.run(['bash', str(ROOT / 'scripts/uninstall.sh')], env=env,
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert not binary.exists()
    assert other.read_text() == 'preserve'
    assert profile.read_text() == 'private profile'
