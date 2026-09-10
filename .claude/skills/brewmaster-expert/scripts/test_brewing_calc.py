#!/usr/bin/env python3
import math
import unittest

from brewing_calc import (
    abv_simple,
    apparent_attenuation,
    dilution_with_water,
    linear_scale,
    plato_to_sg,
    sg_to_plato,
    tinseth_ibu,
)


class BrewingCalcTests(unittest.TestCase):
    def test_attenuation(self):
        self.assertAlmostEqual(apparent_attenuation(1.060, 1.015), 75.0, places=6)

    def test_abv(self):
        self.assertAlmostEqual(abv_simple(1.060, 1.015), 5.90625, places=6)

    def test_sg_plato_roundtrip(self):
        for sg in (1.000, 1.040, 1.060, 1.100):
            self.assertAlmostEqual(plato_to_sg(sg_to_plato(sg)), sg, places=4)

    def test_ten_plato_near_1040(self):
        self.assertTrue(1.039 <= plato_to_sg(10.0) <= 1.041)

    def test_dilution(self):
        result = dilution_with_water(20.0, 1.060, 1.050)
        self.assertGreater(result.final_volume_l, 20.0)
        self.assertGreater(result.water_to_add_l, 0.0)
        # Extract mass should match target side within floating-point precision.
        target_extract = result.final_volume_l * result.target_sg * (sg_to_plato(result.target_sg) / 100.0)
        self.assertAlmostEqual(target_extract, result.extract_mass_kg_approx, places=9)

    def test_tinseth_monotonic_time(self):
        short = tinseth_ibu(12.0, 20.0, 20.0, 15.0, 1.050).ibu
        long = tinseth_ibu(12.0, 20.0, 20.0, 60.0, 1.050).ibu
        self.assertGreater(long, short)

    def test_tinseth_higher_gravity_lower_utilization(self):
        low_g = tinseth_ibu(12.0, 20.0, 20.0, 60.0, 1.040).utilization
        high_g = tinseth_ibu(12.0, 20.0, 20.0, 60.0, 1.090).utilization
        self.assertGreater(low_g, high_g)

    def test_linear_scale(self):
        self.assertAlmostEqual(linear_scale(1.0, 25.0, 120.0), 4.8)

    def test_invalid_dilution(self):
        with self.assertRaises(ValueError):
            dilution_with_water(20, 1.050, 1.060)


if __name__ == "__main__":
    unittest.main()
