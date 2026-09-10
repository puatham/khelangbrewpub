# Brewmaster Expert Agent Skill

Version 0.1.0-alpha, re-audited 2026-09-10.

## What it is

A Claude/Agent Skills package for evidence-driven beer brewing decisions: recipes, Brewfather, mash/water, hops, yeast/fermentation, HERMS/process, QC, packaging and draught.

## Install concept

Place the `brewmaster-expert` directory in the Agent Skills location supported by your Claude environment. The directory name must remain `brewmaster-expert` because the Agent Skills specification requires the `name` field to match the parent directory.

## Structure

- `SKILL.md` — lean operational instructions and routing.
- `references/` — focused on-demand domain references.
- `scripts/` — deterministic calculators and validation tools.
- `evals/` — 100 machine-readable evaluations and scoring guidance.
- `assets/` — schemas for brewery/batch/source data.
- `CORE_SPEC.md` — governing architecture.
- `KNOWLEDGE_SOURCE_MASTER_LIST.md` — knowledge strategy.
- `AUDIT_REPORT.md` — re-audit findings and corrections.

## Important status

This package is **alpha**. Its structure, source facts and calculators are validated locally, but the 100-eval suite must still be run in the actual target Claude environment before claiming model-level pass rates.

## Offline books

Do not add pirated/full copyrighted books to this package. If you own digital copies or have licensed access, create indexes/notes or provide them to your permitted environment and reference focused chapters as needed.
