#!/usr/bin/env bash
# Squash-merge open pull requests that Codex and CodeRabbit have both cleared.
# The policy lives in docs/agents/pull-request-babysitting.md#automatic-merge.
set -euo pipefail

repo=${GITHUB_REPOSITORY:?}
# The merge token may belong to a ruleset bypass actor, so this script checks
# required status checks itself instead of relying on GitHub to refuse.
rules=$(gh api "repos/$repo/rules/branches/main" --paginate --slurp | jq -c '[.[][] | select(.type == "required_status_checks")]')
required=$(jq -c '[.[].parameters.required_status_checks[]]' <<<"$rules")
strict=$(jq -c 'any(.[]; .parameters.strict_required_status_checks_policy == true)' <<<"$rules")
numbers=${*:-$(gh pr list --repo "$repo" --state open --base main --limit 100 --json number | jq -r '.[].number')}

query='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      title state isDraft isCrossRepository baseRefName headRefName headRefOid mergeable
      author { login __typename }
      headRef { compare(headRef: "main") { aheadBy } }
      labels(first: 50) { totalCount nodes { name } }
      reactions(content: THUMBS_UP, first: 100) { nodes { user { login } } }
      comments(last: 100) { nodes { author { login } body createdAt } }
      reviews(last: 100) { nodes { databaseId author { login } state submittedAt commit { oid } } }
      reviewThreads(first: 100) { totalCount nodes { isResolved comments(last: 1) { nodes { createdAt } } } }
      commits(last: 1) { nodes { commit { committedDate statusCheckRollup { contexts(first: 100) {
        totalCount nodes { ... on CheckRun { name status conclusion checkSuite { app { databaseId } } } ... on StatusContext { context state description creator { login } } }
      } } } } }
    }
  }
}'

# Prints "skip: <reason>", "wait: <reason>", "merge" or "dismiss <review id>".
decide='
  .headRefOid as $head
  | (.commits.nodes[0].commit) as $commit
  | ([.reviews.nodes[] | select(.author.login == "coderabbitai" and (.state == "APPROVED" or .state == "CHANGES_REQUESTED" or (.state == "DISMISSED" and .databaseId == $dismissed)))] | last) as $rabbit
  | ([.comments.nodes[] | select(.author.login == "chatgpt-codex-connector" and (.body | contains("Didn'"'"'t find any major issues")))]
     | last | .body // "" | [capture("Reviewed commit:\\*\\* `(?<sha>[0-9a-f]+)`")] | .[0].sha // "") as $codexSha
  # Codex now edits one summary comment instead of posting a clearance; findings arrive as a review of the commit.
  | ([.comments.nodes[] | select(.author.login == "chatgpt-codex-connector" and (.body | contains("<!-- codex-pull-request-review-summary -->")))]
     | last | .body // "" | [capture("Code Review\\*\\* \\| ✅ \\*\\*Completed\\*\\*[^|]*\\| `(?<sha>[0-9a-f]+)`")] | .[0].sha // "") as $codexSummarySha
  # CodeRabbit reports a successful status even when it paused or skipped a commit.
  | (any($commit.statusCheckRollup.contexts.nodes[]?; .context == "CodeRabbit" and .creator.login == "coderabbitai" and .state == "SUCCESS"
      and (.description | IN("Review completed", "Review approved")))) as $rabbitReviewedHead
  | ([$commit.statusCheckRollup.contexts.nodes[]? | {name: (.name // .context), app: .checkSuite.app.databaseId,
      ok: (if .name then .status == "COMPLETED" and (.conclusion | IN("SUCCESS", "SKIPPED")) else .state == "SUCCESS" end)}]) as $checks
  | ([.comments.nodes[].createdAt, .reviews.nodes[].submittedAt, .reviewThreads.nodes[].comments.nodes[].createdAt, $commit.committedDate]
     | map(select(.) | fromdateiso8601) | max) as $lastActivity
  | if .state != "OPEN" then "skip: not open"
    elif .isDraft then "skip: draft"
    elif .isCrossRepository then "skip: fork head"
    elif .baseRefName != "main" then "skip: not targeting main"
    elif .author.__typename != "User" or (.author.login | endswith("[bot]")) then "skip: bot or unavailable author"
    elif .headRefName == "changeset-release/main" then "skip: release pull request"
    elif (.title | ascii_downcase | contains("[wip]") or contains("[skip review]") or contains("version packages")) or any(.labels.nodes[]; .name == "do-not-review")
      then "skip: excluded from CodeRabbit review"
    elif .labels.totalCount != (.labels.nodes | length) then "wait: incomplete label page"
    elif .mergeable != "MERGEABLE" then "wait: not mergeable (\(.mergeable))"
    elif $commit.statusCheckRollup.contexts.totalCount != ($checks | length) then "wait: incomplete check page"
    elif any($required[]; . as $requirement | [$checks[] | select(.name == $requirement.context and ($requirement.integration_id == null or .app == $requirement.integration_id))] | length == 0 or any(.ok | not))
      then "wait: required checks have not all passed"
    elif $strict and (.headRef.compare.aheadBy // 1) > 0 then "wait: the ruleset requires an up-to-date branch and main has moved on"
    # ponytail: fail closed past one page of threads; paginate if PRs outgrow it.
    elif .reviewThreads.totalCount != (.reviewThreads.nodes | length) then "wait: too many review threads to verify"
    elif any(.reviewThreads.nodes[]; .isResolved | not) then "wait: unresolved review threads"
    elif all(.reactions.nodes[]; .user.login != "chatgpt-codex-connector[bot]") then "wait: no Codex 👍"
    elif any(.reviews.nodes[]; .author.login == "chatgpt-codex-connector" and .commit.oid == $head) then "wait: Codex has findings on the head commit"
    elif all($codexSha, $codexSummarySha; . as $sha | $sha == "" or ($head | startswith($sha) | not)) then "wait: Codex has not cleared the head commit"
    elif $rabbit == null then "wait: no CodeRabbit approval"
    elif $rabbit.state == "APPROVED" and $rabbitReviewedHead then "merge"
    elif $now - $lastActivity <= 7200 and $rabbit.state == "APPROVED"
      then "wait: CodeRabbit has not reviewed the head commit and the PR was active in the last 2 hours"
    elif $now - $lastActivity <= 7200 then "wait: CodeRabbit requests changes and the PR was active in the last 2 hours"
    elif $rabbit.state != "CHANGES_REQUESTED" then "merge"
    else "dismiss \($rabbit.databaseId)"
    end'

fetch_pr() {
  gh api graphql -F owner="${repo%/*}" -F name="${repo#*/}" -F number="$number" -f query="$query" |
    jq '.data.repository.pullRequest'
}

evaluate() {
  jq -r --argjson required "$required" --argjson strict "$strict" --argjson now "${AUTO_MERGE_NOW:-$(date -u +%s)}" --argjson dismissed "${1:-0}" "$decide" <<<"$pr"
}

failed=0
for number in $numbers; do
  pr=$(fetch_pr)
  decision=$(evaluate)
  echo "#$number: $decision"
  [[ $decision == merge || $decision == dismiss* ]] || continue
  [[ -z ${DRY_RUN:-} ]] || continue
  head=$(jq -r .headRefOid <<<"$pr")
  # Refresh mutable feedback and exclusions immediately before acting.
  pr=$(fetch_pr)
  decision=$(evaluate)
  if [[ $(jq -r .headRefOid <<<"$pr") != "$head" || ($decision != merge && $decision != dismiss*) ]]; then
    echo "#$number: wait: eligibility changed ($decision)"
    continue
  fi
  if [[ $decision == dismiss* ]]; then
    dismissed=${decision#dismiss }
    if ! gh api -X PUT "repos/$repo/pulls/$number/reviews/$dismissed/dismissals" \
      -f event=DISMISS \
      -f message='Stale: every CodeRabbit thread is resolved and the pull request has been quiet for 2 hours.' >/dev/null; then
      failed=1
      continue
    fi
    # Dismissal is a separate request; newly blocking feedback must stop merging.
    pr=$(fetch_pr)
    decision=$(evaluate "$dismissed")
    if [[ $(jq -r .headRefOid <<<"$pr") != "$head" || $decision != merge ]]; then
      echo "#$number: wait: eligibility changed after dismissal ($decision)"
      continue
    fi
  fi
  gh pr merge "$number" --repo "$repo" --squash --match-head-commit "$head" || failed=1
done
exit "$failed"
