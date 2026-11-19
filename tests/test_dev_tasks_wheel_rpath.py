#!/usr/bin/env python3
"""The site wheel tasks reject DT_RUNPATH and keep a real DT_RPATH."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
DEV_TASKS = REPO / "tests" / "site" / "dev-tasks.sh"


def helper(text):
    lines = text.splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith("rpath_not_runpath()"))
    end = start + 1
    depth = lines[start].count("{") - lines[start].count("}")
    while end < len(lines) and depth > 0:
        depth += lines[end].count("{") - lines[end].count("}")
        end += 1
    return "\n".join(lines[start:end]) + "\n"


class WheelRpathTests(unittest.TestCase):
    def test_tasks_assert_rpath_on_the_three_builders(self):
        text = DEV_TASKS.read_text(encoding="utf-8")
        for task, fn in (
            ("setuptools-gsl", "t_setuptools_gsl"),
            ("meson-python-gsl", "t_meson_python_gsl"),
            ("scikit-build-gsl", "t_scikit_build_gsl"),
        ):
            self.assertIn(fn + "()", text)
            self.assertIn("task " + task + " " + fn, text)
        self.assertGreaterEqual(text.count("rpath_not_runpath "), 3)

    def test_helper_keeps_rpath_and_rejects_runpath(self):
        fn = helper(DEV_TASKS.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory(prefix="eb-local-wheel-rpath-") as td:
            root = Path(td)
            lib = root / "lib"
            lib.mkdir()
            (root / "answer.c").write_text("int answer(void) { return 42; }\n", encoding="utf-8")
            (root / "main.c").write_text(
                "int answer(void); int main(void) { return answer() == 42 ? 0 : 1; }\n",
                encoding="utf-8",
            )
            subprocess.run(
                ["gcc", "-shared", "-fPIC", "-o", str(lib / "libanswer.so"), str(root / "answer.c")],
                check=True,
            )
            good = root / "good"
            bad = root / "bad"
            link = ["gcc", str(root / "main.c"), "-L" + str(lib), "-lanswer"]
            subprocess.run(
                link + ["-Wl,-rpath," + str(lib), "-Wl,--disable-new-dtags", "-o", str(good)],
                check=True,
            )
            subprocess.run(
                link + ["-Wl,-rpath," + str(lib), "-Wl,--enable-new-dtags", "-o", str(bad)],
                check=True,
            )
            kept = subprocess.run(
                ["/bin/bash", "-c", fn + 'rpath_not_runpath "$1" "$2"\n', "rpath", str(good), str(lib)],
                check=False,
            )
            self.assertEqual(kept.returncode, 0)
            dropped = subprocess.run(
                ["/bin/bash", "-c", fn + 'rpath_not_runpath "$1" "$2"\n', "rpath", str(bad), str(lib)],
                check=False,
            )
            self.assertNotEqual(dropped.returncode, 0)
            loaded = subprocess.run(
                ["env", "-i", "PATH=/usr/bin:/bin", str(good)],
                check=False,
            )
            self.assertEqual(loaded.returncode, 0)
            dump = subprocess.run(["readelf", "-d", str(good)], check=True, capture_output=True, text=True)
            self.assertIn("(RPATH)", dump.stdout)
            self.assertNotIn("(RUNPATH)", dump.stdout)
            self.assertIn(str(lib), dump.stdout)


if __name__ == "__main__":
    unittest.main()
