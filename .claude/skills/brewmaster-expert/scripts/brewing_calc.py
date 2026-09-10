#!/usr/bin/env python3
"""Deterministic brewing calculations used by the Brewmaster Expert skill.

These are engineering/brewing estimates, not laboratory measurements. Inputs should be
normalized to the stated reference conditions where appropriate.
"""
from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass, asdict


def _check_sg(value: float, name: str = "SG") -> None:
    if not (0.98 <= value <= 1.25):
        raise ValueError(f"{name}={value} is outside supported range 0.98–1.25")


def apparent_attenuation(og: float, fg: float) -> float:
    _check_sg(og, "OG")
    _check_sg(fg, "FG")
    if og <= 1.0:
        raise ValueError("OG must be greater than 1.000")
    if fg > og:
        raise ValueError("FG cannot exceed OG for apparent attenuation")
    return (og - fg) / (og - 1.0) * 100.0


def abv_simple(og: float, fg: float) -> float:
    """Approximate ABV using the common 131.25 factor."""
    _check_sg(og, "OG")
    _check_sg(fg, "FG")
    if fg > og:
        raise ValueError("FG cannot exceed OG for this ABV estimate")
    return (og - fg) * 131.25


def sg_to_plato(sg: float) -> float:
    """Cubic approximation for wort SG to degrees Plato."""
    _check_sg(sg)
    return -616.868 + 1111.14 * sg - 630.272 * sg**2 + 135.997 * sg**3


def plato_to_sg(plato: float) -> float:
    """Empirical degrees-Plato to wort SG approximation."""
    if not (-2.0 <= plato <= 50.0):
        raise ValueError("Plato is outside supported range -2 to 50")
    return 1.0 + plato / (258.6 - ((plato / 258.2) * 227.1))


@dataclass
class DilutionResult:
    current_volume_l: float
    current_sg: float
    target_sg: float
    final_volume_l: float
    water_to_add_l: float
    extract_mass_kg_approx: float


def dilution_with_water(current_volume_l: float, current_sg: float, target_sg: float) -> DilutionResult:
    """Estimate dilution by conserving extract mass using Plato and wort density.

    Assumptions: no extract loss, water addition only, additive volume approximation,
    and volumes/SG normalized consistently (preferably around 20 C).
    """
    if current_volume_l <= 0:
        raise ValueError("current_volume_l must be positive")
    _check_sg(current_sg, "current SG")
    _check_sg(target_sg, "target SG")
    if target_sg >= current_sg:
        raise ValueError("target SG must be lower than current SG for dilution with water")
    p1 = sg_to_plato(current_sg) / 100.0
    p2 = sg_to_plato(target_sg) / 100.0
    if p1 <= 0 or p2 <= 0:
        raise ValueError("Dilution calculation requires positive extract concentrations")
    # Approximate wort mass: volume L * SG kg/L (water density ~1 kg/L near reference temp)
    extract_mass = current_volume_l * current_sg * p1
    extract_per_l_target = target_sg * p2
    final_volume = extract_mass / extract_per_l_target
    return DilutionResult(
        current_volume_l=current_volume_l,
        current_sg=current_sg,
        target_sg=target_sg,
        final_volume_l=final_volume,
        water_to_add_l=final_volume - current_volume_l,
        extract_mass_kg_approx=extract_mass,
    )


@dataclass
class IBUResult:
    alpha_percent: float
    weight_g: float
    volume_l: float
    boil_min: float
    wort_sg: float
    utilization: float
    ibu: float


def tinseth_ibu(alpha_percent: float, weight_g: float, volume_l: float, boil_min: float, wort_sg: float) -> IBUResult:
    """Tinseth kettle IBU estimate.

    Utilization = 1.65 * 0.000125^(G-1) * (1-exp(-0.04*t))/4.15
    IBU ≈ utilization * mg/L of added alpha acids.
    """
    if not (0 < alpha_percent <= 40):
        raise ValueError("alpha_percent must be >0 and <=40")
    if weight_g <= 0 or volume_l <= 0 or boil_min < 0:
        raise ValueError("weight and volume must be positive; boil_min cannot be negative")
    _check_sg(wort_sg, "wort SG")
    gravity_factor = 1.65 * (0.000125 ** (wort_sg - 1.0))
    time_factor = (1.0 - math.exp(-0.04 * boil_min)) / 4.15
    utilization = gravity_factor * time_factor
    alpha_mg_per_l = weight_g * (alpha_percent / 100.0) * 1000.0 / volume_l
    ibu = utilization * alpha_mg_per_l
    return IBUResult(alpha_percent, weight_g, volume_l, boil_min, wort_sg, utilization, ibu)


def linear_scale(value: float, from_volume_l: float, to_volume_l: float) -> float:
    if from_volume_l <= 0 or to_volume_l <= 0:
        raise ValueError("volumes must be positive")
    return value * to_volume_l / from_volume_l


def _emit(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


def main() -> None:
    parser = argparse.ArgumentParser(description="Brewing calculation helpers")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("attenuation")
    p.add_argument("--og", type=float, required=True)
    p.add_argument("--fg", type=float, required=True)

    p = sub.add_parser("abv")
    p.add_argument("--og", type=float, required=True)
    p.add_argument("--fg", type=float, required=True)

    p = sub.add_parser("sg-to-plato")
    p.add_argument("--sg", type=float, required=True)

    p = sub.add_parser("plato-to-sg")
    p.add_argument("--plato", type=float, required=True)

    p = sub.add_parser("dilute")
    p.add_argument("--volume-l", type=float, required=True)
    p.add_argument("--sg", type=float, required=True)
    p.add_argument("--target-sg", type=float, required=True)

    p = sub.add_parser("tinseth-ibu")
    p.add_argument("--alpha-percent", type=float, required=True)
    p.add_argument("--weight-g", type=float, required=True)
    p.add_argument("--volume-l", type=float, required=True)
    p.add_argument("--boil-min", type=float, required=True)
    p.add_argument("--wort-sg", type=float, required=True)

    p = sub.add_parser("scale")
    p.add_argument("--value", type=float, required=True)
    p.add_argument("--from-volume-l", type=float, required=True)
    p.add_argument("--to-volume-l", type=float, required=True)

    args = parser.parse_args()
    try:
        if args.cmd == "attenuation":
            _emit({"apparent_attenuation_percent": apparent_attenuation(args.og, args.fg),
                   "assumption": "Apparent attenuation from SG readings."})
        elif args.cmd == "abv":
            _emit({"abv_percent_approx": abv_simple(args.og, args.fg),
                   "method": "(OG-FG)*131.25", "assumption": "Approximate ABV, not laboratory alcohol measurement."})
        elif args.cmd == "sg-to-plato":
            _emit({"sg": args.sg, "plato_approx": sg_to_plato(args.sg)})
        elif args.cmd == "plato-to-sg":
            _emit({"plato": args.plato, "sg_approx": plato_to_sg(args.plato)})
        elif args.cmd == "dilute":
            result = dilution_with_water(args.volume_l, args.sg, args.target_sg)
            payload = asdict(result)
            payload["assumptions"] = "Water addition only; extract conserved; volumes/SG normalized consistently."
            _emit(payload)
        elif args.cmd == "tinseth-ibu":
            result = tinseth_ibu(args.alpha_percent, args.weight_g, args.volume_l, args.boil_min, args.wort_sg)
            payload = asdict(result)
            payload["assumptions"] = "Tinseth kettle utilization model; estimate, not lab-measured IBU."
            _emit(payload)
        elif args.cmd == "scale":
            _emit({"scaled_value": linear_scale(args.value, args.from_volume_l, args.to_volume_l),
                   "warning": "Raw linear scaling only; does not correct efficiency, hop utilization, losses, geometry, or yeast requirements."})
    except ValueError as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    main()
