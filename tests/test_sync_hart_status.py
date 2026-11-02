"""STS Unavailable follows the car repository's out_of_service column."""

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "seed")]

import sync_hart_status as sync  # noqa: E402
from generate_hart_seed import load_out_of_service  # noqa: E402

SEED = """insert into `cars` values("1","AA1","4","8","0","Unavailable","0","Hopper","0","8","","0","0");
insert into `cars` values("2","BB2","4","8","0","Empty","0","Boxcar","0","8","","0","0");
insert into `ownership` values("1","1","Unavailable");
insert into `ownership` values("2","1","on");
"""


class PlanTests(unittest.TestCase):
    def test_taking_off_keeps_the_status(self):
        self.assertEqual(
            sync.plan([("2", "BB2", "Loaded", "on")], {"BB2"}),
            [("2", "BB2", "Unavailable", "Loaded")],
        )

    def test_putting_back_restores_the_kept_status(self):
        self.assertEqual(
            sync.plan([("2", "BB2", "Unavailable", "Loaded")], set()),
            [("2", "BB2", "Loaded", "on")],
        )

    def test_seeded_car_comes_back_empty(self):
        self.assertEqual(
            sync.plan([("1", "AA1", "Unavailable", "Unavailable")], set()),
            [("1", "AA1", "Empty", "on")],
        )

    def test_matching_cars_are_left_alone(self):
        self.assertEqual(
            sync.plan([("1", "AA1", "Unavailable", "x"), ("2", "BB2", "Empty", "on")], {"AA1"}), []
        )


class SeedTests(unittest.TestCase):
    def test_reads_cars_and_owners(self):
        self.assertEqual(
            sync.seed_cars(SEED),
            [("1", "AA1", "Unavailable", "Unavailable"), ("2", "BB2", "Empty", "on")],
        )

    def test_rewrites_only_the_changed_car(self):
        changes = sync.plan(sync.seed_cars(SEED), {"AA1", "BB2"})
        out = sync.apply_to_seed(SEED, changes)
        self.assertEqual(sync.plan(sync.seed_cars(out), {"AA1", "BB2"}), [])
        self.assertIn('values("2","BB2","4","8","0","Unavailable","0","Boxcar"', out)
        self.assertIn('`ownership` values("2","1","Empty")', out)
        self.assertIn('`ownership` values("1","1","Unavailable")', out)


class ColumnTests(unittest.TestCase):
    def test_reads_the_column(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "m.csv"
            path.write_text("roster_id,out_of_service\nAA1,yes\nBB2,\n")
            self.assertEqual(load_out_of_service(path), ["AA1"])


if __name__ == "__main__":
    unittest.main()
