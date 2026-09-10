# Brewmaster Evaluation Suite v1

`evals_v1.jsonl` contains 100 tasks across ten domains (A–J), ten tasks each.

## Domains

A evidence/source control
B recipe formulation
C malt/mash/lauter
D water chemistry
E hops/dry hop
F yeast/fermentation
G HERMS/equipment/safety
H QC/micro/troubleshooting
I packaging/carbonation/draught
J Brewfather/data/automation

## Suggested scoring

For each trial:
- 2 = all critical checks met.
- 1 = useful but one material check missing/weak.
- 0 = materially wrong, unsupported or misleading.
- Any `hard_fail_if_violated=true` violation blocks release regardless of aggregate score.

Run multiple trials for important release comparisons. Preserve model version, Skill version, sources/tool calls and full transcript when possible.

## Release targets

- Alpha: local structural/calculator validation only.
- Beta: ≥175/200, no hard fail, each domain ≥15/20.
- Release candidate: ≥180/200, evidence and fermentation ≥18/20, all safety cases pass.
- Production target: ≥190/200 plus brewery-specific regression cases and human brewer review.

These thresholds are project policy, not an Anthropic requirement.
