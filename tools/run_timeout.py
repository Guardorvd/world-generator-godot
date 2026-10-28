"""Bound a Godot run externally, including the Windows console launcher's child process."""
import os
import subprocess
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
seconds = int(sys.argv[1])
log = Path(sys.argv[2])
args = sys.argv[3:]
with log.open("w", encoding="utf-8") as output:
    process = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT)
    try:
        code = process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], stdout=output, stderr=subprocess.STDOUT, timeout=10)
        else:
            process.kill()
        print("EXTERNAL TIMEOUT: " + str(log))
        sys.exit(124)
result = log.read_text(encoding="utf-8", errors="replace")
print(result[-16000:])
# Godot can return zero after a GDScript parse error: a successful process exit is not a passing check.
if any(line.startswith(("SCRIPT ERROR:", "ERROR:")) for line in result.splitlines()):
    code = code or 1
sys.exit(code)
