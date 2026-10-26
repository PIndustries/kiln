#!/usr/bin/env python3
"""Kill a fixture runtime process, then recover its owned journal in a new process.
No live model account, application source, deployment or production state is used.
"""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parents[1]
command = ['swift', 'test', '--build-system', 'native', '--force-resolved-versions',
           '--jobs', '4', '--filter', 'workerCrashJournalAcceptance']
with tempfile.TemporaryDirectory(prefix='kiln-event-crash-') as directory:
    root = Path(directory)
    root.chmod(0o700)
    env = {**os.environ, 'KILN_EVENT_CRASH_STATE': str(root)}
    with (root / 'before-crash.log').open('w') as log:
        child = subprocess.Popen(command, cwd=repo, env={**env, 'KILN_EVENT_CRASH_MODE': 'run'},
                                 stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 180
            while not (root / 'ready').exists():
                if child.poll() is not None or time.monotonic() > deadline:
                    raise AssertionError((root / 'before-crash.log').read_text())
                time.sleep(.1)
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=15)
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=15)
    recovery = subprocess.run(command, cwd=repo, env={**env, 'KILN_EVENT_CRASH_MODE': 'recover'},
                              capture_output=True, text=True, timeout=120)
    assert recovery.returncode == 0, recovery.stdout + recovery.stderr
    assert (root / 'recovered').exists()
    print('PASS forced process kill: partial answer, visible reasoning, source draft, queued context and unmatched tool intent recovered.')
    print('PASS no worker or side effect replayed; a new independent task completed.')
    print('KILN_AGENT_EVENT_CRASH_ACCEPTANCE_COMPLETE')
