"""The zig workflow installs pinned eb-stack 0.8.0 once and runs with zero skips."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "zig.yml"
HEX64 = re.compile(r"\b[0-9a-f]{64}\b")


def job_text() -> str:
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    if "  real-eb-stack:" in lines:
        raise AssertionError("zig.yml duplicates eb-stack setup in a separate real-eb-stack job")
    if "  zig:" not in lines:
        raise AssertionError("zig.yml has no zig job")
    start = lines.index("  zig:")
    body = []
    for line in lines[start + 1 :]:
        if re.fullmatch(r"  [A-Za-z0-9_-]+:", line):
            break
        body.append(line)
    return "\n".join(body)


def tests_reading_the_variable() -> list[str]:
    found = []
    for path in sorted((ROOT / "tests").glob("test_*.py")):
        if path.name != Path(__file__).name and "EB_STACK_BIN" in path.read_text(encoding="utf-8"):
            found.append(path.name)
    return found


class RealEbStackCi(unittest.TestCase):
    def test_the_job_runs_full_discover_and_every_test_reading_the_variable(self) -> None:
        job = job_text()
        self.assertIn(
            'EB_LOCAL_BIN="$PWD/zig-out/bin/eb-local" python3 -m unittest discover -s tests -v',
            job,
        )
        names = tests_reading_the_variable()
        self.assertTrue(names)
        for name in names:
            self.assertIn("-p '%s'" % name, job, "the job does not run tests/%s on the release build" % name)
        for pattern in re.findall(r"-p '([^']+)'", job):
            self.assertIn(
                pattern, names, "the job runs %s, which does not read EB_STACK_BIN" % pattern
            )

    def test_the_job_builds_the_programs_it_tests(self) -> None:
        job = job_text()
        self.assertIn("zig build -Dtest-ops=true", job)
        self.assertIn('EB_LOCAL_BIN="$PWD/zig-out/bin/eb-local"', job)
        self.assertIn("zig build --release=safe --prefix out", job)
        self.assertIn('EB_LOCAL_BIN="$PWD/out/bin/eb-local"', job)

    def test_the_job_installs_a_pinned_release_on_path_without_duplication(self) -> None:
        job = job_text()
        self.assertEqual(job.count("https://github.com/stackhands/eb-stack/releases/download/v0.8.0/"), 1)
        self.assertEqual(job.count("apt-get install"), 1)
        hashes = HEX64.findall(job)
        self.assertGreaterEqual(len(hashes), 2, "expected pinned SHA-256 digests for x86_64 and aarch64")
        self.assertIn("sha256sum --check", job)
        path_export = job.find('>> "$GITHUB_PATH"')
        zsh_install = job.find("zsh")
        discover = job.find("python3 -m unittest discover -s tests -v")
        self.assertGreaterEqual(zsh_install, 0)
        self.assertGreaterEqual(path_export, 0, "the job does not add eb-stack to GITHUB_PATH")
        self.assertLess(zsh_install, discover, "zsh is installed after unittest discover")
        self.assertLess(path_export, discover, "eb-stack is installed after unittest discover")
        self.assertIn('grep -Fx "eb-stack 0.8.0"', job)


if __name__ == "__main__":
    unittest.main()
