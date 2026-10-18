#!/usr/bin/env bash
# Fast-forward main to a validated update candidate.
#
# Inputs (environment): CANDIDATE (commit that carries the `update-candidate`
# status), APP_LOGIN (the automation App's bot login), POLICY (auto or label),
# GH_TOKEN (automation App token), GITHUB_REPOSITORY.
#
# Refusals exit nonzero and move nothing. The push is not forced: if main has
# moved, git rejects it and the pipeline re-prepares and re-validates the open
# source pull requests against the new main.
set -euo pipefail

: "${CANDIDATE:?}" "${APP_LOGIN:?}" "${POLICY:?}" "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}"
repo=$GITHUB_REPOSITORY
api() { gh api "repos/$repo/$1" "${@:2}"; }

refuse() {
  echo "::error::promote-candidate: $*"
  exit 1
}

# 1. Only a commit with a candidate ref is a candidate. A human pull request
#    also gets an `update-candidate` status (pipeline.yml, for the merge gate),
#    and that is not a promotion, so it is ignored here.
ref=$(api "git/matching-refs/candidates" \
  --jq "[.[] | select(.ref | endswith(\"-$CANDIDATE\")) | .ref][0] // empty")
if [ -z "$ref" ]; then
  echo "::notice::promote-candidate: $CANDIDATE is not an update candidate; nothing to promote"
  exit 0
fi

# 2. The candidate's status must be the pipeline's own, and recent: repository
#    rules check the creator (the required status is pinned to the App) and
#    require a successful status within the preceding seven days, and this reads
#    both back so a refusal names the cause instead of surfacing as GH013.
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

# 3. The candidate ref names its pull request and source revision.
rest=${ref#refs/candidates/}
pr=${rest%%/*}
pair=${rest#*/}
source=${pair%%-*}

# 4. The source pull request must still be open, into main, at the source.
pull=$(api "pulls/$pr" --jq '{state, base: .base.ref, head: .head.sha, labels: [.labels[].name]}')
[ "$(jq -r .state <<< "$pull")" = open ] || refuse "pull request #$pr is not open"
[ "$(jq -r .base <<< "$pull")" = main ] || refuse "pull request #$pr does not target main"
[ "$(jq -r .head <<< "$pull")" = "$source" ] || \
  refuse "pull request #$pr moved past $source; the newer revision has its own candidate"

# 5. Policy. label requires the accept-update label on the current source.
case "$POLICY" in
  auto) ;;
  label)
    jq -e '.labels | index("accept-update") != null' <<< "$pull" >/dev/null || \
      refuse "pull request #$pr has no accept-update label"
    # The label says an operator accepted something; the marker says which
    # revision. accept.yml takes the head from the label event itself and posts
    # update-accepted on it, so a push after the label leaves the newer revision
    # unmarked, and the marker read is the latest one for that revision rather than
    # any historic success. Timestamps are deliberately not consulted: a commit's
    # dates say when it claims to have been written, not when it reached the pull
    # request.
    marked=$(api "commits/$source/statuses" \
      --jq '[.[] | select(.context == "update-accepted")][0] | .state // "missing"')
    [ "$marked" = success ] || \
      refuse "pull request #$pr is labelled accept-update but its marker on $source reads '$marked'; remove and re-add the label to accept this revision"
    ;;
  *) refuse "unknown policy '$POLICY'" ;;
esac

# 6. The ref name and the status are data; what promotes is the commit. The ref
#    must resolve to the commit it names, and that commit must descend from the
#    source revision it claims and from the current main.
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

# 7. Fast-forward only. The candidate was fetched from its own ref, so the push
#    lands exactly the validated commit; a moved main rejects it.
git push "https://x-access-token:${GH_TOKEN}@github.com/${repo}.git" "$CANDIDATE:refs/heads/main" || \
  refuse "main moved since candidate $CANDIDATE was prepared; the pipeline re-prepares and re-validates it"

echo "promote-candidate: main fast-forwarded to $CANDIDATE (pull request #$pr)"
