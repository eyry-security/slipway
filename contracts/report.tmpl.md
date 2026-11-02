# {{JOB_NAME}} — {{TASK_TITLE}}

**Status:** {{BUILT_AND_TESTED|BLOCKED|FAILED}}

**Repo / branch:** `{{REPO_PATH}}` / `{{BRANCH}}`

**Base:** `{{BASE_REF}}`

**Commit(s):** `{{COMMIT_SHA}}`

Nothing was pushed, merged, deployed, or restarted.

## Outcome

{{One short paragraph: what the job accomplished and what it deliberately did
not do.}}

## Changes

For each item, name the behavior, the files, and the line references.

1. **{{CHANGE_TITLE}}** — {{CHANGE_DESCRIPTION}}
   - Files: `{{FILE_PATH}}:{{LINE}}`

2. **{{CHANGE_TITLE}}** — {{CHANGE_DESCRIPTION}}
   - Files: `{{FILE_PATH}}:{{LINE}}`

## Tests

| Check | Command | Result |
| --- | --- | --- |
| {{CHECK_NAME}} | `{{TEST_CMD}}` | {{PASS_COUNT}} passed, {{FAIL_COUNT}} failed |

If a check was not run, say why here.

## Decisions and assumptions

- {{DECISION_OR_ASSUMPTION}}
- {{DEVIATION_FROM_SPEC_OR_NONE}}

## Risks and follow-ups

- {{RISK_OR_FOLLOW_UP}}
- {{NONE_IF_NONE}}

## Evidence

- Report: `{{REPORT_PATH}}`
- Run log: `{{RUN_LOG_PATH}}`
- Progress log: `{{PROGRESS_LOG_PATH}}`
