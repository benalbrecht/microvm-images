import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

module_path = Path(__file__).resolve().parents[1] / "orchestrator-cache-maps.py"
spec = importlib.util.spec_from_file_location("orchestrator_cache_maps", module_path)
cache_maps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache_maps)
CacheMappingError = cache_maps.CacheMappingError
apply_cache_map = cache_maps.apply_cache_map


class ApplyCacheMapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.home = root / "home"
        self.cache = root / "cache"
        self.home.mkdir()
        self.cache.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def apply_map(self, mapping):
        apply_cache_map(mapping, self.home, self.cache, uid=os.getuid(), gid=os.getgid())

    def test_creates_symlinks_and_is_idempotent(self):
        mapping = {".m2/repository": "m2", ".gitlibs": "gitlibs"}

        self.apply_map(mapping)
        self.apply_map(mapping)

        self.assertEqual((self.cache / "m2").resolve(), (self.home / ".m2/repository").resolve())
        self.assertEqual((self.cache / "gitlibs").resolve(), (self.home / ".gitlibs").resolve())
        self.assertTrue((self.cache / "m2").is_dir())

    def test_moves_an_existing_home_cache_without_losing_files(self):
        old = self.home / ".cache/pip"
        old.mkdir(parents=True)
        (old / "wheel.whl").write_text("wheel")

        self.apply_map({".cache/pip": "pip"})

        self.assertEqual("wheel", (self.cache / "pip/wheel.whl").read_text())
        self.assertEqual((self.cache / "pip").resolve(), old.resolve())

    def test_conflict_fails_without_overwriting_or_deleting_either_file(self):
        old = self.home / ".cache/pip"
        old.mkdir(parents=True)
        (old / "wheel.whl").write_text("home")
        destination = self.cache / "pip"
        destination.mkdir()
        (destination / "wheel.whl").write_text("cache")

        with self.assertRaisesRegex(CacheMappingError, "conflict"):
            self.apply_map({".cache/pip": "pip"})

        self.assertEqual("home", (old / "wheel.whl").read_text())
        self.assertEqual("cache", (destination / "wheel.whl").read_text())

    def test_rejects_unsafe_paths_and_symlinked_home_components(self):
        for mapping in (
            {"../outside": "pip"},
            {".cache/../pip": "pip"},
            {".cache/pip": "../outside"},
            {"/tmp/pip": "pip"},
            {".cache/pip": "/tmp/pip"},
        ):
            with self.subTest(mapping=mapping):
                with self.assertRaises(CacheMappingError):
                    self.apply_map(mapping)

        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        (self.home / ".cache").symlink_to(outside)
        with self.assertRaisesRegex(CacheMappingError, "(?i)symlink"):
            self.apply_map({".cache/pip": "pip"})

        (self.cache / "nested").symlink_to(outside)
        with self.assertRaisesRegex(CacheMappingError, "(?i)symlink"):
            self.apply_map({".cargo": "nested/cargo"})


if __name__ == "__main__":
    unittest.main()
