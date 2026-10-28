import os
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'install.sh'
BASH = os.environ.get('BASH_PATH') or (r'C:\Program Files\Git\bin\bash.exe' if os.name == 'nt' else shutil.which('bash'))
if not BASH or not pathlib.Path(BASH).is_file():
    raise SystemExit('Bash is required. Set BASH_PATH to its full path if needed.')
source = INSTALLER.read_text(encoding='utf-8')
watcher = source.split("<<'WATCHER'\n", 1)[1].split('\nWATCHER\n', 1)[0] + '\n'
subprocess.run([BASH, '-n', str(INSTALLER)], check=True)

def unix(path):
    result = pathlib.Path(path).resolve().as_posix()
    return '/' + result[0].lower() + result[2:] if len(result) > 2 and result[1] == ':' else result

passed = []

with tempfile.TemporaryDirectory(prefix='ip-watch-test-') as temp:
    base = pathlib.Path(temp)
    bindir = base / 'bin'
    bindir.mkdir()
    config = base / 'config'
    state_dir = base / 'state'
    action_log = base / 'actions'
    program = base / 'watcher.sh'
    program.write_text(watcher.replace('CONFIG_FILE=/etc/default/nezha-ip-watch', f"CONFIG_FILE='{unix(config)}'")
                       .replace('STATE_DIR=/var/lib/nezha-ip-watch', f"STATE_DIR='{unix(state_dir)}'"), encoding='utf-8', newline='\n')
    subprocess.run([BASH, '-n', str(program)], check=True)
    (bindir / 'curl').write_text('''#!/usr/bin/env bash
url=${!#}
case "$url" in
  *amazonaws*) result=${TEST_IP1:-FAIL} ;;
  *ipify*) result=${TEST_IP2:-FAIL} ;;
  *icanhazip*) result=${TEST_IP3:-FAIL} ;;
  *) exit 99 ;;
esac
[[ $result != FAIL ]] || exit 7
printf '%s\\n' "$result"
''', encoding='utf-8', newline='\n')
    (bindir / 'systemctl').write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$TEST_ACTION_LOG"
exit "${TEST_ACTION_FAIL:-0}"
''', encoding='utf-8', newline='\n')
    # Windows cannot apply Linux directory ownership/modes. The deployment
    # checks Linux dependencies; this harness exercises the decision logic.
    if os.name == 'nt':
        (bindir / 'install').write_text('''#!/usr/bin/env bash
[[ $1 == -d && $2 == -m ]] || exit 98
mkdir -p -- "${@:4}"
''', encoding='utf-8', newline='\n')
        (bindir / 'flock').write_text('''#!/usr/bin/env bash
exit "${TEST_LOCK_BUSY:-0}"
''', encoding='utf-8', newline='\n')
    subprocess.run([BASH, '-c', 'chmod +x "$1"/*', '_', unix(bindir)], check=True)

    def configure(action='reboot'):
        config.write_text(f'ACTION={action}\nAGENT_UNIT=nezha-agent.service\nCOOLDOWN_SECONDS=900\nCONFIRMATIONS=2\n', newline='\n')

    def run(ips=('8.8.8.8',)*3, mode='run', fail=False, expected=0):
        env = os.environ.copy()
        env.update({f'TEST_IP{i+1}': ip for i, ip in enumerate(ips)})
        env['TEST_ACTION_LOG'] = unix(action_log)
        env['TEST_ACTION_FAIL'] = '1' if fail else '0'
        # Prefix the mock directory inside Bash so Windows PATH conversion cannot
        # change the fixture paths. The real systemctl is never invoked.
        process = subprocess.run([BASH, '-c', 'export PATH="$1:$PATH"; exec bash "$2" "$3"', '_',
                                  unix(bindir), unix(program), mode], env=env,
                                 capture_output=True, text=True, encoding='utf-8', errors='replace')
        assert process.returncode == expected, (process.returncode, process.stdout, process.stderr)
        return process.stdout

    def actions():
        return action_log.read_text().splitlines() if action_log.exists() else []

    def state():
        return (state_dir / 'state').read_text().split()

    def set_state(baseline='8.8.8.8', pending='-', count=0, last=0):
        state_dir.mkdir(exist_ok=True)
        (state_dir / 'state').write_text(f'{baseline} {pending} {count} {last}\n', newline='\n')

    def mark(name):
        passed.append(name)

    configure()
    run(mode='status')
    assert not (state_dir / 'state').exists() and not actions()
    mark('status does not initialize baseline or restart')

    run()
    assert state() == ['8.8.8.8', '-', '0', '0'] and not actions()
    mark('first successful check initializes without reboot')

    run()
    assert not actions()
    mark('unchanged IP does not reboot')

    run(('1.1.1.1',)*3)
    assert state()[1:3] == ['1.1.1.1', '1'] and not actions()
    mark('single changed sample waits for confirmation')

    run(('1.1.1.1',)*3)
    assert actions() == ['reboot'] and state()[0] == '1.1.1.1'
    mark('two changed checks request reboot and save new baseline')

    run(('1.1.1.1',)*3)
    assert actions() == ['reboot']
    mark('same new IP never causes a second reboot')

    run(('9.9.9.9',)*3)
    run(('9.9.9.9',)*3)
    assert actions() == ['reboot'] and state()[0] == '1.1.1.1'
    mark('cooldown defers a different IP change')

    set_state('1.1.1.1', '9.9.9.9', 2, 0)
    run(('9.9.9.9',)*3)
    assert actions() == ['reboot', 'reboot'] and state()[0] == '9.9.9.9'
    mark('deferred change runs after cooldown')

    set_state()
    run(('1.1.1.1',)*3)
    run(('FAIL',)*3)
    assert state()[1:3] == ['-', '0']
    run(('1.1.1.1',)*3)
    assert len(actions()) == 2
    mark('query failure breaks consecutive confirmations')

    set_state()
    for ip in ['192.168.1.1', '999.1.2.3', '127.0.0.1', '10.0.0.1',
               '100.64.0.1', '169.254.1.1', '::1', 'hello', '8.8.8.8\n1.1.1.1']:
        run((ip,)*3)
        assert state() == ['8.8.8.8', '-', '0', '0'] and len(actions()) == 2
    mark('malformed, multiline, private, loopback, CGNAT and IPv6 answers ignored')

    run(('1.1.1.1', '9.9.9.9', '8.8.4.4'))
    assert state() == ['8.8.8.8', '-', '0', '0']
    mark('three disagreeing sources do not restart')

    run(('1.1.1.1', 'FAIL', '1.1.1.1'))
    assert state()[1:3] == ['1.1.1.1', '1']
    mark('two agreeing sources work when another source fails')

    set_state()
    run(('1.1.1.1',)*3)
    run(('9.9.9.9',)*3)
    assert state()[1:3] == ['9.9.9.9', '1'] and len(actions()) == 2
    mark('flapping candidates reset confirmation count')

    run()
    assert state()[1:3] == ['-', '0']
    mark('return to baseline clears pending change')

    configure('agent')
    set_state()
    run(('1.1.1.1',)*3)
    run(('1.1.1.1',)*3)
    assert actions()[-1] == 'restart nezha-agent.service'
    mark('agent mode only requests Agent restart')

    configure('reboot')
    set_state()
    run(('1.1.1.1',)*3)
    run(('1.1.1.1',)*3, fail=True, expected=1)
    assert state()[0] == '1.1.1.1'
    n = len(actions())
    run(('1.1.1.1',)*3)
    assert len(actions()) == n
    mark('failed action does not trigger repeated reboot requests')

    (state_dir / 'state').write_text('bad untrusted state\n')
    run(expected=1)
    assert len(actions()) == n
    mark('corrupt state fails safely without action')

    configure('unsupported')
    run(expected=1)
    assert len(actions()) == n
    mark('invalid configuration fails safely without action')

print('Bash syntax checks: installer and embedded watcher passed')
for name in passed:
    print('PASS:', name)
print(f'{len(passed)} behavioral checks passed; all restart/reboot calls were mocked.')
