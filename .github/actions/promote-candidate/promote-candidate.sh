#!/usr/bin/env bash
# Fast-forward main to an authorized candidate and emit its SHA after the push.
set -euo pipefail

: "${CANDIDATE:?}" "${APP_LOGIN:?}" "${POLICY:?}" "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_OUTPUT:?}"
repo=$GITHUB_REPOSITORY
api() { gh api "repos/$repo/$1" "${@:2}"; }

refuse() {
  echo "::error::promote-candidate: $*"
  exit 1
}

# Human revisions have no candidate ref and are not promoted.
ref=$(api "git/matching-refs/candidates" \
  --jq "[.[] | select(.ref | endswith(\"-$CANDIDATE\")) | .ref][0] // empty")
if [ -z "$ref" ]; then
  echo "::notice::promote-candidate: $CANDIDATE is not an update candidate; nothing to promote"
  exit 0
fi

# Verify the latest App-issued status and its required seven-day freshness.
status=$(api "commits/$CANDIDATE/statuses" \
  --jq '[.[] | select(.context == "update-candidate")][0] // {}')
creator=$(jq -r '.creator.login // empty' <<< "$status")
state=$(jq -r '.state // empty' <<< "$status")
created=$(jq -r '.created_at // empty' <<< "$status")
[ "$creator" = "$APP_LOGIN" ] || refuse "candidate status was posted by '${creator:-nobody}', not $APP_LOGIN"
[ "$state" = success ] || refuse "latest candidate status is '${state:-missing}'"
[ -n "$created" ] || refuse "candidate status has no creation time; re-validate this revision"
age=$(($(date -u +%s) - $(date -u -d "$created" +%s)))
[ "$age" -lt 604800 ] || \
  refuse "the candidate status succeeded $((age / 86400)) days ago; a required status check must have succeeded within seven days, so re-validate this revision"

# The candidate ref encodes its pull request and source revision.
rest=${ref#refs/candidates/}
pr=${rest%%/*}
pair=${rest#*/}
source=${pair%%-*}

# The source must still be open into main at the recorded revision.
pull=$(api "pulls/$pr" --jq '{state, base: .base.ref, head: .head.sha, labels: [.labels[].name]}')
[ "$(jq -r .state <<< "$pull")" = open ] || refuse "pull request #$pr is not open"
[ "$(jq -r .base <<< "$pull")" = main ] || refuse "pull request #$pr does not target main"
[ "$(jq -r .head <<< "$pull")" = "$source" ] || \
  refuse "pull request #$pr moved past $source; the newer revision has its own candidate"

# Label policy requires acceptance of the exact source revision.
case "$POLICY" in
  auto) ;;
  label)
    jq -e '.labels | index("accept-update") != null' <<< "$pull" >/dev/null || \
      refuse "pull request #$pr has no accept-update label"
    marked=$(api "commits/$source/statuses" \
      --jq '[.[] | select(.context == "update-accepted")][0] | .state // "missing"')
    [ "$marked" = success ] || \
      refuse "pull request #$pr is labelled accept-update but its marker on $source reads '$marked'; remove and re-add the label to accept this revision"
    ;;
  *) refuse "unknown policy '$POLICY'" ;;
esac

# Validate the ref's SHA and ancestry before the fast-forward.
git fetch --no-tags --quiet origin "$ref"
fetched=$(git rev-parse FETCH_HEAD)
[ "$fetched" = "$CANDIDATE" ] || refuse "ref $ref resolves to $fetched, not $CANDIDATE"
git fetch --no-tags --quiet origin main
if ! git merge-base --is-ancestor "$source" "$CANDIDATE"; then
  refuse "candidate $CANDIDATE does not descend from source $source"
fi
if ! git merge-base --is-ancestor origin/main "$CANDIDATE"; then
  refuse "main moved past candidate $CANDIDATE; the pipeline re-prepares and re-validates it"
fi

# A non-forced push rejects a concurrent main advance.
git push "https://x-access-token:${GH_TOKEN}@github.com/${repo}.git" "$CANDIDATE:refs/heads/main" || \
  refuse "main moved since candidate $CANDIDATE was prepared; the pipeline re-prepares and re-validates it"

echo "promoted_sha=$CANDIDATE" >> "$GITHUB_OUTPUT"
echo "promote-candidate: main fast-forwarded to $CANDIDATE (pull request #$pr)"
