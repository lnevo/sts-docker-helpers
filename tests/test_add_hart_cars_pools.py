import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

import add_hart_cars  # noqa: E402


class LivePools(unittest.TestCase):
    def test_pools_for_deleted_shipments_are_dropped(self):
        kept = add_hart_cars.keep_live_pools(["9", "76", "10"], {"9", "10"}, "CSX1")
        self.assertEqual(kept, ["9", "10"])

    def test_nothing_dropped_when_all_exist(self):
        self.assertEqual(add_hart_cars.keep_live_pools(["9"], {"9"}, "CSX1"), ["9"])


if __name__ == "__main__":
    unittest.main()
