# {{JOB_NAME}} — status

STATUS {{JOB_NAME}} STATE={{RUNNING|DONE|BLOCKED|FAILED}} UPDATED={{TIMESTAMP}}
STARTED: {{START_TIMESTAMP}}
REPO: {{REPO_PATH}}
BRANCH: {{BRANCH}}
REPORT: {{REPORT_PATH}}

## Current step

{{What is happening right now.}}

## Completed

- {{COMPLETED_ITEM}}
- {{COMPLETED_ITEM}}

## Next

- {{NEXT_ITEM}}
- {{NEXT_ITEM}}

## Blockers

- {{BLOCKER_OR_NONE}}

## Evidence

- Progress log: `{{PROGRESS_LOG_PATH}}`
- Run log: `{{RUN_LOG_PATH}}`
