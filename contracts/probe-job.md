# Probe job — run this before any real dispatch

This is the mandatory first job on every new builder. It proves the toolchain,
the agent environment, the repo checkout, and the report contract before a real
spec is allowed onto the machine.

Fill the placeholders once per builder, then run it through `run.sh`.

```text
PROBE_NAME:   {{PROBE_NAME}}
REPO_PATH:    {{REPO_PATH}}
BRANCH:       {{BRANCH}}
BASE_BRANCH:  {{BASE_BRANCH}}
REPORT_PATH:  {{REPORT_PATH}}
PROGRESS_LOG: {{PROGRESS_LOG_PATH}}
RUN_LOG:      {{RUN_LOG_PATH}}
```

## Task

Do only these steps, in order. Stop at the first failure and report it.

1. Verify the toolchain. Record the output of:

   ```bash
   node --version
   npm --version
   opencode --version
   git --version
   ```

2. Verify the agent environment by **name only**. Do not print values. Confirm
   that the agent env file exists and contains the required keys:

   ```text
   DEEPSEEK_API_KEY
   OPENCODE_SERVER_PASSWORD
   ```

   Report each key as `present` or `missing`. Never `cat`, `echo`, or paste the
   file.

3. Verify repository access. Create a fresh branch `{{BRANCH}}` from
   `{{BASE_BRANCH}}`, confirm the work tree is clean, and record the starting
   commit.

4. Do a trivial, reversible task: write `PROBE.md` at the repo root containing
   the UTC timestamp, branch name, and the versions collected in step 1. Commit
   it on `{{BRANCH}}`.

5. Write the report to `{{REPORT_PATH}}` using `contracts/report.tmpl.md`.
   Include the step-by-step checks, the commit hash, and a clear `PASS` or
   `FAIL` verdict.

## Hard boundaries

- Do not push, merge, deploy, restart services, or change any other file.
- Do not print or copy environment values.
- Do not start real work if any check fails.
- If `opencode` or `node` is missing, stop and report the missing tool; do not
  attempt to reinstall the toolchain from inside this job.

## Definition of done

- Every check above ran and is recorded.
- The probe commit exists on `{{BRANCH}}`.
- The report exists at `{{REPORT_PATH}}` with a `PASS` or `FAIL` verdict.
