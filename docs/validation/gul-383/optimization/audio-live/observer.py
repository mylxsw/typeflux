"""Content-free identity observation that tolerates a child exiting between ps snapshots."""
import subprocess


def started_identity(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=,comm='], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None
