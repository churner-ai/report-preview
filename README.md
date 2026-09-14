# `churner-ai/report-preview`

Post one **preview-contract** event to Churner from your CI.

Churner needs to know where the preview environment for a pull request is,
and whether it is up. Before this existed, the answer was a URL somebody
typed into a prompt — which goes stale on the next push, says nothing about
a build that failed, and cannot tell a torn-down preview from a live one.
This action reports each state change as it happens, and everything
downstream (the churn agent's `churn_wait_for_preview`, the tracker's
validation flow, the item page's preview chip) reads the resulting record.

## Setup

1. In Churner, open the project's **Access** settings and mint a **preview
   token**. It is shown once — store it immediately as a repository secret,
   e.g. `CHURNER_PREVIEW_TOKEN`.
2. Note the project key (`MC`, `TRK`, …).

The preview token is not an API token and not a personal one. It reaches
exactly one route for exactly one project, and re-minting it revokes the
previous one — which is how you rotate it.

## Inputs

| Input | Required | Default | Meaning |
|---|---|---|---|
| `token` | yes | — | The project's preview token, from a repository secret. |
| `project` | yes | — | Churner project key, e.g. `MC`. |
| `type` | yes | — | `building` \| `ready` \| `failed` \| `destroyed`. |
| `pr` | on a non-PR event | the event's PR number | Pull-request number. Inferred from `github.event.pull_request.number`. |
| `sha` | on a non-PR event | the event's head commit | Head commit the preview was built from, 7-64 hex chars. Inferred from `github.event.pull_request.head.sha`. |
| `url` | on `ready` | `''` | Where the preview answers. https only, no credentials in the authority. |
| `health-path` | no | `''` | Rooted path a health check hits under `url`, e.g. `/api/health`. Defaults to `/` at rest. |
| `database-name` | no | `''` | The Postgres database THIS preview's app uses on the environment's preview instance, e.g. `preview_my_branch` (lower-case letters, digits, underscore). Lets Churner's agents query the pull request's own database on the preview environment. |
| `expires-in` | no | `''` | How long the preview is expected to live — `48h`, `90m`, `7d`, `30s`. Sent as an absolute `expiresAt`. **The unit suffix is required**; see below. |
| `build-log-url` | no | this workflow run's page | Where this attempt's build log can be read. |
| `error` | no | `''` | Why a `failed` failed. Truncated at 2000 chars by the contract, never refused. |
| `tracker-url` | no | `https://churner.ai` | Base URL of the Churner instance. Must be **https** unless the host is loopback. |
| `max-attempts` | no | `5` | Tries before the step fails. Only 429 / 5xx / network failures are retried. |
| `backoff-seconds` | no | `1` | Base of the exponential backoff. Any single wait is clamped at 60s. |

### `expires-in` needs its unit

`48` is refused, not read as 48 seconds. Every author who writes a bare
number means hours, and accepting it would have set an expiry two days
early — in the direction that makes a live preview look expired, with
nothing downstream able to tell.

### `tracker-url` must be https

The preview token rides in a header on **every** request, so plaintext hands
it to anything on the path. Loopback (`127.0.0.1`, `localhost`, `[::1]`) is
the one exception, because that is how the action's own tests run and there
is no network to intercept. A host that merely *starts* with `localhost` —
`localhost.example.com` — is not loopback and is refused.

### `sha` is the head commit, not `github.sha`

On a `pull_request` event `github.sha` is the **merge** commit — a commit no
branch carries. `(project, pr, sha)` is the record's identity, so keying on
the merge commit would file every report under a commit nobody can check
out. The inferred default is `github.event.pull_request.head.sha`, which is
the right one; if you pass `sha` yourself, pass that and not `github.sha`.

### `pr`, `sha` and `build-log-url` are inferred

On a `pull_request` event you do not have to pass them — the action reads
them from the event and from the run it is executing in. Pass them
explicitly on **any other trigger** (`push`, `workflow_dispatch`,
`repository_dispatch`, a reusable workflow called from one), because those
events carry no pull request and the inference resolves to nothing. It then
fails loudly, naming the input, rather than posting a record keyed on an
empty commit:

```
report-preview: input 'pr' is required (the pull-request number)
```

Anything you pass explicitly always wins over the inferred value.

## The four-step workflow

```yaml
name: Preview

on:
  pull_request:
    types: [opened, synchronize, reopened, closed]

permissions:
  contents: read

jobs:
  preview:
    if: github.event.action != 'closed'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # 1. building — at the START of the job, before anything can fail.
      #    Without it, a build that dies in its first minute is
      #    indistinguishable from a build that was never attempted.
      - uses: churner-ai/report-preview@v1
        with:
          token: ${{ secrets.CHURNER_PREVIEW_TOKEN }}
          project: MC
          type: building

      - id: deploy
        run: ./scripts/deploy-preview.sh    # sets steps.deploy.outputs.url

      - name: Wait for the preview to answer
        run: |
          for i in $(seq 1 60); do
            curl -fsS "${{ steps.deploy.outputs.url }}/api/health" && exit 0
            sleep 5
          done
          exit 1

      # 2. ready — AFTER the health check, never before. A `ready` is a
      #    promise that the URL answers; posting it at deploy time makes
      #    every reader wait on a promise the pipeline had not checked.
      - uses: churner-ai/report-preview@v1
        with:
          token: ${{ secrets.CHURNER_PREVIEW_TOKEN }}
          project: MC
          type: ready
          url: ${{ steps.deploy.outputs.url }}
          health-path: /api/health
          expires-in: 48h

      # 3. failed — on ANY earlier failure. `if: failure()` is what makes
      #    the record say "the build broke" instead of sitting at
      #    `building` forever, which reads as "still going".
      - if: failure()
        uses: churner-ai/report-preview@v1
        with:
          token: ${{ secrets.CHURNER_PREVIEW_TOKEN }}
          project: MC
          type: failed
          error: Preview build failed — see the build log.

  # 4. destroyed — on PR close, in its own job so it runs whether the PR
  #    merged or was abandoned.
  teardown:
    if: github.event.action == 'closed'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./scripts/teardown-preview.sh
      - if: always()
        uses: churner-ai/report-preview@v1
        with:
          token: ${{ secrets.CHURNER_PREVIEW_TOKEN }}
          project: MC
          type: destroyed
```

## What the action does about each response

| Response | Behaviour |
|---|---|
| `200` | Exit 0. This includes `duplicate: true` — a redelivery moved nothing, which is a success for the poster, so a re-run of your workflow is never red for doing the right thing. |
| `400` | Exit 1, printing every validation error the contract reported. The response lists them all at once rather than first-failure-wins, because a CI job reads one response and moves on. |
| `401` | Exit 1. The token is wrong, missing, or has been rotated. Re-mint it in the project's Access settings and update the repository secret. |
| `409` | Exit 1. The transition was refused — e.g. a `ready` for a preview already recorded as `destroyed`. The body names `from` and `to`. |
| `429` | Retried, honouring `Retry-After` **from the response headers** (never from the body, which is written by whoever is answering) and clamping any single wait at 60s. The tracker rate-limits *failed* token verifications per project; a token that has verified once is not subject to it. |
| `5xx` / network failure | Retried with exponential backoff, then exit 1. |

Only `429` and `5xx` are retried. A `400`, `401` or `409` will answer
identically on the next attempt, and retrying one only delays the red step
that tells you what to fix.

## Transitions

The contract enforces a state machine, so an out-of-order redelivery cannot
walk a torn-down preview back to alive:

- `destroyed` is accepted from anywhere. Teardown is unconditional.
- `ready` and `failed` follow `building`, or stand alone.
- `ready` **also** follows `failed` — re-running a workflow on the same
  commit after a flaky failure is ordinary, and refusing it would leave the
  record saying `failed` while a live preview answers.
- `ready` never follows `destroyed`.
- `failed` never follows `ready`. A preview that answered and then stopped
  is a teardown, not a failed build.

## The token is never an argument, and never printed

Two separate claims, both enforced by tests.

Inputs cross into the program as **environment variables**, and the
`Authorization` header is fed to curl over **stdin** (`-H @-`). Putting it in
`-H "Authorization: Bearer $TOKEN"` would place the credential in curl's
argv, where `ps` shows it to every other process on the runner — which on a
shared self-hosted runner means every other repository's jobs. A source
assertion greps every `curl` line for the token variable, because the leak is
invisible from outside: the request looks identical either way.

Nothing in the action echoes the token on any path — happy, refused, or
retry-exhausted. GitHub's log masking is a backstop, not a licence to print
it.

## Developing this action

**This file, `action.yml` and `report-preview.sh` are authored in the
[churner monorepo](https://github.com/churner-ai/churner)**, under
`github-actions/report-preview/`. The standalone `churner-ai/report-preview`
repository exists only because `uses:` resolves against a repository; it is a
published copy, produced by `scripts/release-report-preview.sh`, and a patch
made there is overwritten by the next release without ever having run against
the tests.

The tests live in the monorepo at `server/tests/report-preview-action.test.ts`
and **execute this script**, against a Fastify stub of the tracker's events
route — so they test the shipped program rather than a re-parse of the YAML.

```
# from a churner monorepo checkout
cd server && npx vitest run tests/report-preview-action.test.ts
```
