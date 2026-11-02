# {{JOB_NAME}} — {{TASK_TITLE}}

You are building in the repository at `{{REPO_PATH}}`.
Work on a fresh branch `{{BRANCH}}` cut from `{{BASE_BRANCH}}`.
The local repo is the source of truth. Do not push, merge, deploy, or restart
services.

## Context

Read these before changing anything:

- `{{SPEC_PATH}}` — the spec this job implements.
- `{{CONTEXT_PATH}}` — supporting notes, analysis, or prior reports.
- Files directly named in the task below.

If the spec and this prompt disagree, stop and record the conflict in the
report instead of guessing.

## Task

{{TASK}}

## Outcome

The job is done when:

- {{ACCEPTANCE_1}}
- {{ACCEPTANCE_2}}
- {{ACCEPTANCE_3}}
- the relevant test command passes: `{{TEST_CMD}}`
- the report exists at `{{REPORT_PATH}}`

## Constraints

- Commit only to `{{BRANCH}}`. Do not touch `{{BASE_BRANCH}}`.
- Do not push, merge, deploy, restart services, or rotate credentials.
- Do not change files outside the task scope without saying why in the report.
- Do not add secrets, tokens, keys, real hostnames, IP addresses, account
  emails, personal names, employer names, or target names to code, tests,
  comments, commit messages, or reports. Use placeholders such as
  `builder-1.example`, `203.0.113.10`, and `git@example.com`.
- Do not print environment values. Check that required keys are present by
  name only.
- If a step is blocked, stop and write the blocker to the report rather than
  inventing a workaround.

## Report contract

Write exactly one report to `{{REPORT_PATH}}` using the shape in
`contracts/report.tmpl.md`:

1. Status and branch/commit.
2. Outcome, item by item.
3. What changed, with `file:line` references.
4. Tests run and results.
5. Decisions, assumptions, and any deviations from the spec.
6. Risks and follow-ups.

Keep it factual. If something was not run, say so explicitly.

## Hard boundaries

- Never run destructive operations against production.
- Never modify live orchestration scripts or directories outside the assigned
  repository.
- Never commit an `agent-env`, `.env`, private key, or token file.
- Never include real third-party targets or customer data in the repository.
- Stop and report if the prompt path, repository, branch, or report path is
  not what you expect.
