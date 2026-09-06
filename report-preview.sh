#!/usr/bin/env bash
#
# report-preview — post ONE preview-contract event to Churner.
#
# The body of `churner-ai/report-preview@v1`. It lives in its own file
# rather than inline in `action.yml`'s `run:` because a shell program
# embedded in YAML can only be tested by re-parsing the YAML, and a test
# that re-derives the thing under test is testing its own parser. Here the
# test executes THIS file, byte for byte, the way Actions does.
#
# ## The token never becomes an argument
#
# Every input arrives as an environment variable, and the Authorization
# header is fed to curl over STDIN (`-H @-`, curl >= 7.55). `-H "Authorization:
# Bearer $TOKEN"` would put the credential in curl's argv, where `ps` shows
# it to every other process on the runner — which on a shared self-hosted
# runner is every other repository's jobs. Nothing here echoes it either:
# not on the happy path, not in an error, not under `set -x` (never enabled).
#
# ## What it guarantees
#
#   - Exit 0 on 200 (including `duplicate: true` — a redelivery moved
#     nothing, which is a success for the poster).
#   - Exit 1 on 400 / 401 / 409, printing the response body. Those are the
#     three refusals a pipeline must SEE: a malformed event, a bad token,
#     an out-of-order transition. Retrying any of them changes nothing.
#   - Retry on 429 and 5xx with a bounded backoff, honouring `Retry-After`
#     when the server sends one. The tracker's failed-token budget refills
#     at 1/s, so a single second of patience is the difference between a
#     red pipeline and a recorded event.
#   - A network failure is retried on the same schedule as a 5xx.
#
# ## Why the JSON is built here rather than by `jq`
#
# `jq` is present on every GitHub-hosted runner and on approximately no
# self-hosted container image. The escaping below is `sed` plus a two-rule
# `awk`, and removes a dependency the action would otherwise carry into
# environments it does not control.

set -euo pipefail

TRACKER_URL="${REPORT_PREVIEW_TRACKER_URL:-https://churner.ai}"
TOKEN="${REPORT_PREVIEW_TOKEN:-}"
PROJECT="${REPORT_PREVIEW_PROJECT:-}"
TYPE="${REPORT_PREVIEW_TYPE:-}"
PR="${REPORT_PREVIEW_PR:-}"
SHA="${REPORT_PREVIEW_SHA:-}"
URL="${REPORT_PREVIEW_URL:-}"
HEALTH_PATH="${REPORT_PREVIEW_HEALTH_PATH:-}"
EXPIRES_IN="${REPORT_PREVIEW_EXPIRES_IN:-}"
BUILD_LOG_URL="${REPORT_PREVIEW_BUILD_LOG_URL:-}"
ERROR_TEXT="${REPORT_PREVIEW_ERROR:-}"
MAX_ATTEMPTS="${REPORT_PREVIEW_MAX_ATTEMPTS:-5}"
BACKOFF_BASE="${REPORT_PREVIEW_BACKOFF_BASE_SECONDS:-1}"

# Ceiling on any single wait. A server (or something impersonating one) can
# put `Retry-After: 604800` on a 429; honouring it verbatim would hang the
# job for a week against a step timeout nobody set.
MAX_DELAY_SECONDS=60

die() {
  echo "report-preview: $1" >&2
  exit 1
}

HEADER_FILE=""
cleanup() {
  [ -n "$HEADER_FILE" ] && rm -f "$HEADER_FILE"
  return 0
}
trap cleanup EXIT

# JSON-escape one string.
#
# Deliberately NOT awk's `RS="\0"`: on BWK awk and mawk — the awk on
# ubuntu-latest — an empty RS means PARAGRAPH mode, which collapses runs of
# blank lines and silently deletes them from the value. An `error` input is
# routinely a stack trace with blank lines between frames, and losing them
# would corrupt the one field that says why a build broke.
#
# So: `sed` does the character escapes (its replacement semantics are
# unambiguous, unlike awk's `gsub` backslash handling), and awk joins the
# LINES with a literal `\n` using the default record separator. The trailing
# newline `printf '%s\n'` adds is what makes a value that itself ends in a
# newline survive the round trip.
json_escape() {
  local tab
  tab="$(printf '\t')"
  printf '%s\n' "$1" \
    | tr -d '\015' \
    | tr '\000-\010\013\014\016-\037' '[ *]' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/${tab}/\\\\t/g" \
    | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

# Portable epoch -> `YYYY-MM-DDTHH:MM:SSZ`. GNU date wants `-d @N`, BSD
# date wants `-r N`; trying both keeps the action working on macOS runners
# and on Alpine images alike.
iso_from_epoch() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# `48h` / `90m` / `7d` / `30s` -> an absolute ISO instant. A duration is what
# a workflow author can state (`expires-in: 48h` beside a 48-hour teardown
# schedule); an instant is what the contract stores, because a record read
# tomorrow has to say when the preview goes away, not how long it had left
# when someone posted.
#
# The SUFFIX IS REQUIRED. A bare `48` reads to its author as hours and would
# have meant 48 seconds — an expiry two days wrong, in the direction that
# makes a live preview look expired, and nothing downstream could tell.
expires_at_from_duration() {
  local raw="$1" n unit secs
  case "$raw" in
    *[smhd]) ;;
    *) die "expires-in needs a unit suffix — s, m, h or d (got '$raw'; write '48h', not '48')" ;;
  esac
  n="${raw%[smhd]}"
  unit="${raw#"$n"}"
  case "$n" in
    ''|*[!0-9]*) die "expires-in must be digits followed by s, m, h or d (got '$raw')" ;;
  esac
  case "$unit" in
    s) secs=$(( n )) ;;
    m) secs=$(( n * 60 )) ;;
    h) secs=$(( n * 3600 )) ;;
    d) secs=$(( n * 86400 )) ;;
    *) die "expires-in must be digits followed by s, m, h or d (got '$raw')" ;;
  esac
  iso_from_epoch "$(( $(date -u +%s) + secs ))"
}

# The tracker URL must be https, because the preview token rides in a header
# on every request and plaintext hands it to anything on the path. Loopback
# is the one exception: it is how this script is tested, and there is no
# network to intercept.
assert_tracker_url() {
  local url="$1" authority host
  case "$url" in
    https://*) return 0 ;;
    http://*) authority="${url#http://}" ;;
    *) die "tracker-url must be an http(s) URL (got '$url')" ;;
  esac
  authority="${authority%%/*}"
  case "$authority" in
    # Bracketed IPv6 literal — the colons are part of the host, so the port
    # split below would cut it in half.
    \[*\]*) host="${authority%%\]*}]" ;;
    *)      host="${authority%%:*}" ;;
  esac
  case "$host" in
    127.0.0.1|localhost|'[::1]') return 0 ;;
  esac
  die "tracker-url must use https (got '$url') — the preview token rides on every request"
}

# ---------------------------------------------------------------------------
# Input check — refused HERE rather than by the tracker
# ---------------------------------------------------------------------------
#
# The five below are what the request cannot be built without, plus the
# three that decide where it goes and how hard it tries. Everything else the
# CONTRACT owns: the server validates and reports every violation at once,
# and re-deriving those rules in shell would be a second contract that
# drifts from the first. `url` on a `ready` is the clearest case — it is
# refused server-side with a sentence, and duplicating the check here would
# mean two places to update when it changes.
[ -n "$TOKEN" ] || die "input 'token' is required (the project's preview token)"
[ -n "$PROJECT" ] || die "input 'project' is required (the Churner project key, e.g. MC)"
[ -n "$TYPE" ] || die "input 'type' is required (building | ready | failed | destroyed)"
[ -n "$PR" ] || die "input 'pr' is required (the pull-request number)"
[ -n "$SHA" ] || die "input 'sha' is required (the head commit the preview was built from)"

# The key is interpolated into the URL PATH. Constraining it to the shape a
# key actually has is simpler than encoding, and it refuses a traversal or a
# query-string injection outright instead of encoding one into a 404.
case "$PROJECT" in
  *[!A-Za-z0-9_-]*) die "input 'project' must be a project key of letters, digits, '-' or '_' (got '$PROJECT')" ;;
esac

assert_tracker_url "$TRACKER_URL"

case "$MAX_ATTEMPTS" in
  ''|*[!0-9]*) die "input 'max-attempts' must be a positive integer (got '$MAX_ATTEMPTS')" ;;
esac
[ "$MAX_ATTEMPTS" -ge 1 ] || die "input 'max-attempts' must be at least 1 (got '$MAX_ATTEMPTS')"
case "$BACKOFF_BASE" in
  ''|*[!0-9]*) die "input 'backoff-seconds' must be a non-negative integer (got '$BACKOFF_BASE')" ;;
esac

# `if`, not `[ … ] && …`: under `set -e` a false one-line AND-list at top
# level IS a failing command, so every optional field would have exited the
# script the moment it was absent.
append_optional() {
  local key="$1" value="$2"
  if [ -n "$value" ]; then
    BODY="${BODY},\"${key}\":\"$(json_escape "$value")\""
  fi
}

BODY="{\"type\":\"$(json_escape "$TYPE")\",\"pr\":\"$(json_escape "$PR")\",\"sha\":\"$(json_escape "$SHA")\""
append_optional url "$URL"
append_optional healthPath "$HEALTH_PATH"
append_optional buildLogUrl "$BUILD_LOG_URL"
append_optional error "$ERROR_TEXT"
if [ -n "$EXPIRES_IN" ]; then
  # Assigned on its own line, then appended. `die` inside a command
  # substitution exits only the SUBSHELL, so folding this into the string
  # above would leave the script's survival resting on `set -e` reading the
  # substitution's status — true today, and quietly false the moment
  # somebody wraps the expression.
  EXPIRES_AT="$(expires_at_from_duration "$EXPIRES_IN")" || exit 1
  BODY="${BODY},\"expiresAt\":\"${EXPIRES_AT}\""
fi
BODY="${BODY}}"

ENDPOINT="${TRACKER_URL%/}/api/projects/${PROJECT}/previews/events"
HEADER_FILE="$(mktemp "${TMPDIR:-/tmp}/report-preview.XXXXXX")"

echo "report-preview: ${TYPE} PR #${PR} @ ${SHA} -> ${ENDPOINT}"

attempt=1
while : ; do
  # Headers land in their OWN file, not interleaved with the body on stdout:
  # `Retry-After` is read from the header block alone, so a response body
  # that happens to contain a line reading `Retry-After: 604800` cannot
  # steer the retry. `--fail` is deliberately NOT used — it would collapse
  # 400/401/409/429 into one exit code and throw away the body, which is the
  # only thing that says WHICH refusal it was.
  #
  # The Authorization header comes over stdin (`-H @-`). See the header
  # comment: an argument is world-readable through `ps`.
  : > "$HEADER_FILE"
  RAW="$(
    printf 'Authorization: Bearer %s\n' "$TOKEN" \
      | curl --silent --show-error --location \
          --max-time 30 \
          -D "$HEADER_FILE" \
          -o - \
          -w '\nreport_preview_http_status=%{http_code}' \
          -X POST "$ENDPOINT" \
          -H @- \
          -H 'Content-Type: application/json' \
          -H 'Accept: application/json' \
          --data-binary "$BODY" 2>&1 || true
  )"
  STATUS="$(printf '%s' "$RAW" | sed -n 's/^report_preview_http_status=//p' | tail -n 1)"
  RESPONSE="$(printf '%s' "$RAW" | sed '$d')"
  [ -n "$STATUS" ] || STATUS=0

  case "$STATUS" in
    2*)
      echo "report-preview: recorded (HTTP ${STATUS})."
      # The body carries `duplicate` and the stored record; printing it
      # makes a redelivery legible in the workflow log rather than
      # indistinguishable from a first post.
      printf '%s\n' "$RESPONSE" | tail -n 5
      exit 0
      ;;
    400|401|409)
      echo "report-preview: refused with HTTP ${STATUS} — this will not succeed on a retry." >&2
      printf '%s\n' "$RESPONSE" >&2
      exit 1
      ;;
  esac

  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "report-preview: giving up after ${attempt} attempts (last status ${STATUS})." >&2
    printf '%s\n' "$RESPONSE" >&2
    exit 1
  fi

  # `Retry-After` when the server states one, from the HEADER block only,
  # and clamped: the events route answers a throttled token with a budget
  # that refills at 1/s, and no legitimate value here is worth more than a
  # minute of a CI job.
  RETRY_AFTER="$(
    tr -d '\r' < "$HEADER_FILE" \
      | sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' \
      | tail -n 1
  )"
  if [ -n "$RETRY_AFTER" ]; then
    DELAY="$RETRY_AFTER"
  else
    DELAY=$(( BACKOFF_BASE * (2 ** (attempt - 1)) ))
  fi
  if [ "$DELAY" -gt "$MAX_DELAY_SECONDS" ]; then
    echo "report-preview: clamping a ${DELAY}s retry delay to ${MAX_DELAY_SECONDS}s." >&2
    DELAY="$MAX_DELAY_SECONDS"
  fi
  echo "report-preview: HTTP ${STATUS} — retrying in ${DELAY}s (attempt ${attempt}/${MAX_ATTEMPTS})." >&2
  sleep "$DELAY"
  attempt=$(( attempt + 1 ))
done
