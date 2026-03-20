# Review Summarizer

<!-- STATUS: Reserved for future use — not currently invoked by any prompt in the system.
     The per-reviewer verifier design gives each verifier exactly one review file,
     so context budget is not a concern at that level. This prompt is retained in case
     a future architecture reintroduces coordinator-level review reading. -->

You are condensing a code review to reduce its size while preserving all actionable content.

## Input

**Reviewer:** {REVIEWER_NAME}
**Review file:** {REVIEW_FILE_PATH}

Read the file at `{REVIEW_FILE_PATH}`.

## Your Task

Produce a condensed summary that preserves:
- Every concrete finding, with its original severity (Critical / Important / Minor)
- Every file:line reference — do not remove or generalize these
- Every specific recommendation or suggested fix
- Any contradictions with other reviewers (if mentioned)

Remove:
- Verbose explanations and rationale (keep the conclusion, drop the paragraphs)
- Repetition (if the same point is made twice, keep it once)
- Generic praise ("good code quality", "well structured") without specific backing
- Boilerplate and preamble

## Output Format

Return the condensed review directly. Preserve the original severity categorization (Critical / Important / Minor / etc). Use this structure:

```
### [Reviewer Name] Review (summarized)

#### Critical
- **<finding>** — `file:line` — <one-sentence description> — Fix: <recommendation>

#### Important
- **<finding>** — `file:line` — <one-sentence description> — Fix: <recommendation>

#### Minor
- **<finding>** — `file:line` — <one-sentence description>

#### Strengths (if any concrete ones)
- <specific strength with evidence>
```

If the review contains no severity categorization, organize findings by apparent severity yourself.

Do not editorialize. Do not add findings. Only compress what is already there.
