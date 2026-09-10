# Validated source registry

**Audit date:** 2026-09-10

Use this registry as a starting point. Re-check volatile sources before material decisions.

## Agent Skills / evaluation architecture

| ID | Source | Status / use |
|---|---|---|
| AS01 | https://agentskills.io/specification | Current Agent Skills format: required `SKILL.md`, YAML `name` + `description`, optional `scripts/`, `references/`, `assets/`; <5000-token instructions and <500-line main file recommended; shallow references recommended. |
| AS02 | https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills | Anthropic overview and progressive disclosure rationale. |
| AS03 | https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents | Evaluation terminology: task, trial, grader, transcript; use multi-trial evals where appropriate. |

## Core brewing books / offline library

These are references to legally obtained copies; do not bundle full copyrighted text into this Skill.

| ID | Source | Validated fact / role |
|---|---|---|
| BK01 | John Palmer, *How to Brew*, 4th ed., Brewers Publications (2017) | General brewing foundation. Official publisher currently sells 4th ed. |
| BK01W | https://howtobrew.com/ | Free site is mostly the 3rd edition with updates; Palmer calls it approximately “version 3.5.” Do not treat as 4th-edition full text. |
| BK02 | Palmer & Kaminski, *Water: A Comprehensive Guide for Brewers* (2013) | Water chemistry. |
| BK03 | White & Zainasheff, *Yeast: The Practical Guide to Beer Fermentation* | Yeast/fermentation foundation; supplement with current manufacturer data. |
| BK04 | John Mallett, *Malt: A Practical Guide from Field to Brewhouse* (2014) | Malt science and handling. |
| BK05 | Stan Hieronymus, *For the Love of Hops* | Hop foundation; supplement with current hop-lot/research data. |
| BK06 | Bamforth & Fox, *Scientific Principles of Malting and Brewing*, 2nd ed. (2023) | Current validated 2nd edition; science foundation. |
| BK07 | Wolfgang Kunze, ed. Olaf Hendel, *Technology: Brewing and Malting*, 6th ed. (2019) | Current validated 6th edition in ASBC store; professional process reference. |
| BK08 | Jack Hendler & Joe Connolly, *Modern Lager Beer* (2024) | Contemporary lager process/reference. |
| BK09 | Mary Pellettieri, *Quality Management: Essential Planning for Breweries* (2015) | Brewery quality-management system. |
| BK10 | Matt Stinchfield, *Brewery Safety: Principles, Processes, and People* (2023) | Brewery safety framework. |
| BK11 | Stan Hieronymus, *Brewing with Wheat* | Wheat/Weizen/Wit style and process reference. |
| BK12 | Scott Janish, *The New IPA* | Modern hop-forward practitioner/research synthesis; verify important mechanisms against primary/professional sources. |

## Professional science, quality and style

| ID | Source | Use |
|---|---|---|
| PS01 | https://www.mbaa.com/technical-quarterly | MBAA Technical Quarterly: peer-reviewed and applied brewing technical literature. |
| PS02 | ASBC Methods of Analysis | Validated brewing analytical methods; access may require membership/subscription. |
| PS03 | EBC / Analytica-EBC | Standard analytical methods and quality-control reference. |
| PS04 | https://www.bjcp.org/style/2021/guidelines/ | Current published BJCP beer guideline set checked 2026-09-10: 2021 Beer Style Guidelines. |
| PS05 | https://www.bjcp.org/bjcp-style-guidelines/errata/ | Errata for BJCP guidelines. |
| PS06 | https://www.brewersassociation.org/educational-publications/draught-beer-quality-manual/ | Draught system design, dispense gas, balance, cleaning, sanitation and pouring. Page dated 2026-02-01. |
| PS07 | https://www.brewersassociation.org/educational-publications/hop-creep-technical-brief/ | Hop Creep Technical Brief, published 2026-06-30; primary current practical reference for hop-creep conditions and risks. |
| PS08 | https://www.brewersassociation.org/safety/ | Brewery Safety resource hub. |
| PS09 | https://www.brewersassociation.org/brewing-industry-updates/co2-hazards/ | Current BA CO2 hazard guidance: gas accumulation can displace oxygen; use calibrated monitoring/ventilation as appropriate. |

## Brewfather

| ID | Source | Current fact checked 2026-09-10 |
|---|---|---|
| BF01 | https://docs.brewfather.app/api | REST API v2 for new integration; v1 deprecated; returned data in metric units. |
| BF02 | https://docs.brewfather.app/profiles/equipment | Equipment profile includes batch volume, efficiency, losses, boil-off and advanced multi-vessel settings; calibrate to actual system. |
| BF03 | https://docs.brewfather.app/getting-started/setting-up-your-equipment-profile | Measure real boil-off/losses and refine efficiency; includes multi-vessel HLT/mash-loss guidance. |
| BF04 | https://docs.brewfather.app/brewing-knowledge/water-chemistry | General mash pH 5.2–5.6 measured around 20°C; direct measured pH emphasized over RA alone. |
| BF05 | https://docs.brewfather.app/recipes/water-calculator | Water calculator; predicted pH at 20°C; cooled measurement recommended. |
| BF06 | https://docs.brewfather.app/integrations/ispindel | iSpindel interval 900 s or higher; default gravity input Plato; `[SG]` name tag for SG formula; attach to batch. |
| BF07 | https://docs.brewfather.app/integrations/rapt | RAPT Pill/Temperature Controller integration; SG/temperature/target temp/battery/RSSI; ≥15-min logging; attach to batch. |
| BF08 | https://docs.brewfather.app/devices | Device troubleshooting and data interpretation. |

## Yeast manufacturers

| ID | Source | Current validated fact |
|---|---|---|
| YE01 | https://www.lallemandbrewing.com/en/continental-europe/products/lalbrew-verdant-ipa/ | Verdant IPA: attenuation 75–82%, 18–25°C, medium flocculation, 12% ABV tolerance, pitch 50–100 g/hL. |
| YE01T | Current Verdant technical data sheet linked from YE01 | Current TDS agrees with 18–25°C and medium flocculation. |
| YE01OLD | Older Lallemand catalog | Legacy conflict: older catalog can show narrower 18–23°C and different flocculation wording. Treat as historical, not current. |
| YE02 | https://wyeastlab.com/product/weihenstephan-weizen/ | Wyeast 3068: 73–77% attenuation, 18–24°C, low flocculation; temperature/wort density/pitch influence banana/clove; overpitch can suppress banana. |
| YE03 | https://fermentis.com/en/product/safale-wb-06/ | WB-06: *S. cerevisiae var. diastaticus*; dosage 50–80 g/hL, ideally 18–26°C. |
| YE04 | https://www.whitelabs.com/index.php/yeast-single?id=134&type=YEAST | WLP066 current live page: 75–82%, low-medium flocculation, 18–22°C, STA1 negative. |
| YE04OLD | White Labs WLP066 older technical PDF | Legacy conflict: PDF shows 17–21°C. Prefer current live product page unless a newer dated TDS supersedes it. |

## Hops

| ID | Source | Use |
|---|---|---|
| HP01 | https://tools.yakimachief.com/ | YCH lot analysis lookup and brewing tools. |
| HP02 | YCH individual lot pages | Use actual lot AA/beta, total oil, HSI, oil components, sensory data and survivable compounds when available. |
| HP03 | https://www.yakimachief.com/about-us/news/yakima-chief-hops-launches-new-website | 2026-08-05 announcement of Shop-By-Lot experience. |
| HP04 | https://www.yakimachief.com/resources/five-new-features-on-the-yakima-chief-hops-website | 2026-08-10 details of lot comparison/oil/sensory access. |

## KegLand practical process references

| ID | Source | Use |
|---|---|---|
| KL01 | https://docs.kegland.com.au/recipes/readme/fresh-fresh-wort-kit-fwk/fresh3-directory/extra-strong-ale-fresh-recipe-kb24217 | Example explicitly says follow SG steps over time steps if possible. Treat as KegLand practical recipe guidance, not universal fermentation science. |
| KL02 | https://docs.kegland.com.au/recipes/fresh-fresh-wort-kit-fwk/fresh-ipa-fresh-wort-kits/double-trouble-dipa-fresh-recipe-kb04609 | DIPA example with gravity-based stages and dry-hop timing. Use only as practitioner/equipment ecosystem guidance. |

## Formula reference

| ID | Source | Use |
|---|---|---|
| FM01 | https://howtobrew.com/section-1/chapter-5/ | Tinseth utilization form: gravity factor and boil-time factor. Formula is a model/estimate. |
| FM02 | https://howtobrew.com/section-3/chapter-18/ | °Plato definition as extract mass percentage and use of wort volume × density × extract fraction for extract mass. |
| FM03 | https://www.brewersfriend.com/plato-to-sg-conversion-chart/ | Empirical SG↔Plato conversion equations used by the calculator; treat as approximations, especially outside normal wort ranges. |

## Source ingestion rule

Before adding a new cached fact, record at minimum:
`source_id`, `title`, `organization/author`, `source_type`, `edition/version`, `publication/revision date if known`, `retrieved_at`, `applicability`, `URL/document ID`, `notes/conflicts`.
