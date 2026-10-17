"""Exercise the real watch loop with empty temporary input and a bounded wait stub."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(os.environ.get("EMBY_WATCH_SOURCE_ROOT", Path(__file__).resolve().parents[1]))


class WatchLockTests(unittest.TestCase):
    def run_script(self, language, foreign_lock=False):
        with tempfile.TemporaryDirectory(prefix="emby-watch-test-") as directory:
            root = Path(directory)
            input_dir = root / "input"
            output_dir = root / "output"
            binary_dir = root / "bin"
            for path in (input_dir, output_dir / "_state", binary_dir):
                path.mkdir(parents=True, exist_ok=True)
            lock = output_dir / "_state/lock_ROOT"
            if foreign_lock:
                lock.write_text(str(os.getpid()) + "\n")
            wait = binary_dir / "sleep"
            wait.write_text('''#!/bin/sh
set -eu
count=0
if [ -f "$TEST_SLEEP_COUNTER" ]; then read -r count < "$TEST_SLEEP_COUNTER"; fi
count=$((count + 1))
printf '%s\\n' "$count" > "$TEST_SLEEP_COUNTER"
if [ "$count" -ge 2 ]; then exit 73; fi
''')
            wait.chmod(0o755)
            script = ROOT / language / "EmbyConvert/ffmpeg/scripts/hevc_batch.sh"
            result = subprocess.run(
                ["bash", str(script)],
                env={"PATH": str(binary_dir) + os.pathsep + os.defpath,
                     "IN_ROOT": str(input_dir), "OUT_ROOT": str(output_dir),
                     "WATCH": "1", "WAIT_SEC": "0",
                     "TEST_SLEEP_COUNTER": str(root / "wait-count")},
                capture_output=True, text=True, timeout=10,
            )
            lock_content = lock.read_text() if lock.exists() else None
            return result, lock_content

    def test_watch_completes_two_iterations_with_one_owned_lock(self):
        for language in ("de", "en"):
            with self.subTest(language=language):
                result, lock = self.run_script(language)
                self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
                self.assertEqual(result.stdout.count("Start: MODE=run"), 2)
                self.assertIsNone(lock, "Owned lock must be removed when the runner exits")

    def test_running_other_process_keeps_its_lock_and_blocks_work(self):
        for language in ("de", "en"):
            with self.subTest(language=language):
                result, lock = self.run_script(language, foreign_lock=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("Start: MODE=run", result.stdout)
                self.assertEqual(lock, str(os.getpid()) + "\n")


if __name__ == "__main__":
    unittest.main()
