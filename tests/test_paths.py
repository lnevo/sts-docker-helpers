"""STS data paths: backups resolve to sts-docker-data, and no script names an old root."""

import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "lib"), str(ROOT / "seed")]
import sts_paths  # noqa: E402


def resolve_with_bash(fake_root: Path) -> subprocess.CompletedProcess:
    script = fake_root / "sts-helpers" / "bin" / "x.sh"
    return subprocess.run(
        ["bash", "-c", f'source "{ROOT}/lib/paths.sh"; sts_helpers_resolve_paths "{script}"; echo "$BACKUPS_DIR"'],
        capture_output=True,
        text=True,
        env={k: v for k, v in os.environ.items() if k not in ("STS_BACKUPS_DIR", "STS_DOCKER")},
    )


class BackupsDir(unittest.TestCase):
    def test_python_default_is_sibling_data_folder(self):
        env = {k: v for k, v in os.environ.items() if k != "STS_BACKUPS_DIR"}
        with unittest.mock.patch.dict(os.environ, env, clear=True):
            self.assertEqual(sts_paths.backups_dir(), ROOT.parent / "sts-docker-data" / "backups")

    def test_env_overrides(self):
        with unittest.mock.patch.dict(os.environ, {"STS_BACKUPS_DIR": "/tmp/x"}):
            self.assertEqual(sts_paths.backups_dir(), Path("/tmp/x"))

    def test_bash_finds_data_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp).resolve()
            (base / "sts-helpers/bin").mkdir(parents=True)
            (base / "sts-docker").mkdir()
            (base / "sts-docker-data/backups").mkdir(parents=True)
            result = resolve_with_bash(base)
            self.assertEqual(result.stdout.strip(), str(base / "sts-docker-data/backups"), result.stderr)

    def test_bash_fails_without_creating_anything(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp).resolve()
            (base / "sts-helpers/bin").mkdir(parents=True)
            (base / "sts-docker").mkdir()
            result = resolve_with_bash(base)
            self.assertIn("STS backups not found", result.stderr)
            self.assertEqual(sorted(p.name for p in base.iterdir()), ["sts-docker", "sts-helpers"])


class SeedGenerator(unittest.TestCase):
    def test_import_creates_no_folder_and_targets_backups(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "not-made"
            with unittest.mock.patch.dict(os.environ, {"STS_BACKUPS_DIR": str(target)}):
                spec = importlib.util.spec_from_file_location("seed_gen", ROOT / "seed/generate_hart_seed.py")
                module = importlib.util.module_from_spec(spec)
                sys.modules["seed_gen"] = module
                spec.loader.exec_module(module)
            self.assertEqual(module.DEFAULT_OUTPUT, target / "hart_seed0")
            self.assertFalse(target.exists())


class NoOldRoots(unittest.TestCase):
    def test_tracked_files_name_no_old_root(self):
        names = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
        pattern = re.compile(r"sts-backups|sts-database|sts-images|~/sts\b|/sts/sts-|Desktop/HART|/Users/lnevo")
        hits = []
        for name in names.splitlines():
            path = ROOT / name
            if name == "tests/test_paths.py" or not path.is_file() or path.is_symlink():
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            hits += [f"{name}:{n}" for n, line in enumerate(text.splitlines(), 1) if pattern.search(line)]
        self.assertEqual(hits, [])


if __name__ == "__main__":
    unittest.main()
