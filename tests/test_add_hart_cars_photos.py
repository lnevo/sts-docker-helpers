import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

import add_hart_cars  # noqa: E402


class FinalImage(unittest.TestCase):
    def test_jpg_source_name_finds_the_png_crop(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "CSXT_hopper_01.png").write_bytes(b"x")
            old = add_hart_cars.FINAL
            add_hart_cars.FINAL = Path(tmp)
            try:
                found = add_hart_cars.final_image("CSXT_hopper_01.jpg")
                missing = add_hart_cars.final_image("nope.jpg")
            finally:
                add_hart_cars.FINAL = old
        self.assertEqual(found.name, "CSXT_hopper_01.png")
        self.assertIsNone(missing)


if __name__ == "__main__":
    unittest.main()
