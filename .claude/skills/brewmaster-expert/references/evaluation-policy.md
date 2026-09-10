# Evaluation policy

Follow evaluation-driven development.

## Principles

- Test representative real tasks, not only trivia.
- Include source conflicts, missing-data cases, sensor disagreement, safety traps and cross-domain decisions.
- Grade task success criteria, not exact wording.
- Run multiple trials for important release decisions because model outputs vary.
- Preserve transcripts/tool traces when the environment allows.
- Maintain capability evals and regression evals.

## Release gate

Alpha: structural validation + calculator tests only.
Beta: ≥ 87.5% weighted eval score, no hard safety failure, with supervised use.
Release candidate: ≥ 90%, evidence routing and fermentation ≥ 90%, all safety cases pass.
Production target: ≥ 95% plus brewery-specific regression cases and human brewer review.

Do not claim that this skill passed the suite unless it has actually been run in the target Claude environment.
