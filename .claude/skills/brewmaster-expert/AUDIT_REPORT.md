# Brewmaster Expert Re-Audit Report

**Audit date:** 2026-09-10
**Package:** brewmaster-expert v0.1.0-alpha

## Scope

This audit restarted from the foundation rather than assuming earlier drafts were correct. It checked:

1. Agent Skills file-format constraints and progressive-disclosure guidance.
2. Core brewing-book editions/titles used as foundation.
3. Current brewing style, science, safety and draught sources.
4. Current Brewfather API/device/equipment/water documentation.
5. Current manufacturer facts used as evaluation “gold facts.”
6. Hop-creep and hop-lot rules.
7. KegLand gravity-stage guidance and its proper evidence class.
8. Skill structure, reference paths, deterministic calculators and evaluation-file integrity.

## Confirmed Agent Skills requirements

Source: https://agentskills.io/specification

Confirmed:
- A Skill is a directory containing at minimum `SKILL.md`.
- YAML frontmatter requires `name` and `description`.
- Name must be lowercase alphanumeric/hyphen, max 64 chars, no leading/trailing/consecutive hyphens, and must match the parent directory.
- Description max 1024 chars.
- Optional `scripts/`, `references/`, `assets/` are supported conventions.
- Main instructions <5000 tokens recommended and `SKILL.md` under 500 lines recommended.
- References should be focused and shallow; avoid deeply nested reference chains.

Package result: local validator reports 267 lines and ~1760 rough instruction tokens; all direct references exist and are one level below the skill root.

## Confirmed evaluation guidance

Anthropic sources:
- https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills
- https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents

Confirmed: representative evaluations should drive Skill development; agent evals benefit from explicit tasks, grading criteria, trials and preserved traces/transcripts. Model outputs vary, so important comparisons should use multiple trials.

Project correction: the 175/200, 180/200 and 190/200 release thresholds in this package are **project-defined thresholds**, not Anthropic requirements. This is now stated explicitly.

## Confirmed book/reference editions

- *How to Brew* — official Brewers Publications currently sells the 4th edition (2017). The free howtobrew.com site explicitly says it is mostly 3rd-edition text with updates, approximately “version 3.5.”
- *Scientific Principles of Malting and Brewing* — validated current 2nd edition, published 2023, by Charles W. Bamforth and Glen P. Fox.
- *Technology: Brewing and Malting* — validated 6th edition, published 2019, Wolfgang Kunze / edited by Olaf Hendel.
- *Modern Lager Beer* — validated 2024 title by Jack Hendler and Joe Connolly.
- *Quality Management: Essential Planning for Breweries* — validated Mary Pellettieri title, 2015.
- *Brewery Safety: Principles, Processes, and People* — validated Matt Stinchfield title, 2023.
- Brewers Publications confirms the Brewing Elements series contains Water, Malt, For the Love of Hops and Yeast.

Correction from earlier drafts: sources that had not been individually re-validated for exact edition/metadata were removed from the **core audited registry** rather than being presented as equally verified. They may be added later after source-level validation.

## Confirmed current BJCP status

Source: https://www.bjcp.org/style/2021/guidelines/

On 2026-09-10 the live BJCP site continues to present the **2021 Beer Style Guidelines** as its beer guideline set. The site also maintains an errata page.

Policy confirmed: BJCP is used for style/sensory/competition context, not as universal process law. This matches BJCP's own warning about misuse of the guidelines beyond their intended role.

## Confirmed Brewers Association references

- Draught Beer Quality Manual page dated 2026-02-01; covers line cleaning, system design/components, dispense gas and balance, pouring, sanitation and growlers.
- Hop Creep Technical Brief published 2026-06-30 by Arnbjørn Stokholm and Thomas H. Shellhammer. It identifies the relevant conditions for hop creep and highlights alcohol, diacetyl, CO2 and package-overpressure consequences.
- Current Brewery Safety resources include CO2 hazard guidance emphasizing that CO2 can displace oxygen and that calibrated monitoring/ventilation are important where accumulation is possible.

Package consequence: hop-creep/package-safety and gas-safety cases are hard-fail evals.

## Confirmed Brewfather facts

Current official docs checked 2026-09-10:
- REST API **v2** is the current API for new integrations; v1 is deprecated.
- API data are returned in metric units.
- Equipment profiles require system-specific calibration of efficiency, losses and boil-off; multi-vessel guidance includes Mash-Tun Loss and HLT deadspace/minimum HLT water concerns.
- Brewfather's current water documentation gives a general mash-pH target of 5.2–5.6 measured around 20°C and recommends direct measurement rather than relying on residual alkalinity alone.
- iSpindel normal integration: 900-second interval or higher; values sent more often than every 15 minutes are ignored; Brewfather expects Plato unless `[SG]` is in the device name; attach the device to the batch.
- RAPT integration: supports RAPT Pill and RAPT Temperature Controller, logs SG/temperature and other fields, ignores data faster than 15 minutes, and requires attachment to the batch.

Correction: the Skill treats all these as volatile software facts that should be re-checked, not memorized indefinitely.

## Confirmed yeast manufacturer facts

### LalBrew Verdant IPA
Current product page/TDS:
- attenuation 75–82%;
- 18–25°C;
- medium flocculation;
- alcohol tolerance 12% ABV;
- pitch rate 50–100 g/hL.

Important conflict found: an older Lallemand catalog shows narrower/different values (including 18–23°C and different flocculation wording). This legacy discrepancy is now explicitly used as a source-version test.

### Wyeast 3068
Current page:
- apparent attenuation 73–77%;
- temperature 18–24°C;
- low flocculation;
- states temperature, wort density and lower pitch rate can shift ester expression; overpitch can strongly reduce banana character;
- sulfur can occur and dissipate with conditioning.

Package consequence: the Skill rejects the simplistic rule “20°C for banana, then lower to 18°C to create clove.”

### Fermentis WB-06
Current page identifies ingredients as *Saccharomyces cerevisiae var. Diastaticus* and gives 50–80 g/hL, ideally 18–26°C.

Package consequence: claiming WB-06 is definitely non-diastatic is a hard failure.

### White Labs WLP066
Current live product page:
- 75–82% attenuation;
- low-medium flocculation;
- 18–22°C;
- STA1 negative.

An older official tech PDF shows 17–21°C. The Skill must expose this version conflict and prefer current live information unless a newer dated technical sheet supersedes it.

## Confirmed hop-lot policy

YCH's current lot tools expose actual-lot values including alpha acids, beta acids, total oil, HSI, oil components, sensory information and, for some lots, survivable-compound data. YCH launched a Shop-By-Lot website experience in August 2026.

Package consequence: actual lot/package data outrank generic hop-variety averages for batch formulation when available.

## Confirmed KegLand evidence classification

Current KegLand recipe documentation contains explicit practical guidance to follow SG steps over time steps when possible in several recipes. This supports gravity-aware process control as a practitioner/system example.

Correction: the package **does not** promote KegLand's recipe guidance into a universal fermentation law. Fermentation is instead multi-signal state-driven: gravity slope + expected attenuation + temperature + yeast + pressure + elapsed time + dry-hop/QC state + brewery history.

## Formula audit

Implemented calculators:
- apparent attenuation: `(OG-FG)/(OG-1) * 100`;
- approximate ABV: `(OG-FG)*131.25`, explicitly labeled approximate;
- SG → Plato cubic approximation plus the common empirical Plato → SG equation;
- water dilution using extract-mass conservation based on Plato and wort density;
- Tinseth kettle IBU model using the gravity/time utilization functions reproduced by How to Brew;
- raw linear scaling with an explicit warning that it does not account for utilization, efficiency, losses, geometry or pitching.

No carbonation-pressure, acid-dose, electrical or pressure-vessel calculator is included yet because those require additional validated model/data decisions and would create false confidence if implemented prematurely.

Local unit tests: 9/9 pass.

## Evaluation audit

`evals/evals_v1.jsonl` contains exactly 100 unique cases:
- A–J domains;
- 10 cases per domain;
- source-conflict tests;
- missing-input tests;
- calculator tests;
- sensor-disagreement tests;
- hop-creep/package-safety tests;
- pressure/electrical/CO2-related safety reasoning;
- Brewfather API/device tests.

The suite validates structure/rubrics only. **It has not yet measured Claude's actual performance.** Run it in the target Claude environment across multiple trials before claiming a model pass rate.

## Final audit status

### Passed now
- Agent Skills structural design.
- Progressive-disclosure architecture.
- Current high-value source facts listed above.
- Known source conflicts captured explicitly.
- Local file/reference integrity.
- Calculator unit tests.
- Evaluation count/domain/ID validation.

### Not yet claimable
- Claude performance score on the 100 evals.
- Production readiness.
- Complete ingestion/indexing of user-owned brewing books.
- Calibration against the brewery's actual equipment/batch history.
- Advanced calculators (water acidification, carbonation equilibrium, pitching viability, heat-transfer/HERMS model) until their model assumptions are explicitly validated.

## Audit conclusion

The package is appropriately labeled **v0.1.0-alpha**. Its architecture is ready to install and benchmark, but calling it “complete” or “production-ready” before target-model evaluation and brewery-data calibration would be inaccurate.
