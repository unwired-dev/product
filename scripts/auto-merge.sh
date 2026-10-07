#!/usr/bin/env bash
# Squash-merge open pull requests that Codex and CodeRabbit have both cleared.
# The policy lives in docs/agents/pull-request-babysitting.md#automatic-merge.
set -euo pipefail

repo=${GITHUB_REPOSITORY:?}
now=${AUTO_MERGE_NOW:-$(date -u +%s)}
# The merge token may belong to a ruleset bypass actor, so this script checks
# required status checks itself instead of relying on GitHub to refuse.
required=$(gh api "repos/$repo/rules/branches/main" |
  jq -c '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]')
numbers=${*:-$(gh pr list --repo "$repo" --state open --base main --limit 100 --json number | jq -r '.[].number')}

query='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      title state isDraft isCrossRepository headRefName headRefOid mergeable
      labels(first: 50) { nodes { name } }
      reactions(content: THUMBS_UP, first: 100) { nodes { user { login } } }
      comments(last: 100) { nodes { author { login } body createdAt } }
      reviews(last: 100) { nodes { databaseId author { login } state submittedAt } }
      reviewThreads(first: 100) { totalCount nodes { isResolved comments(last: 1) { nodes { createdAt } } } }
      commits(last: 1) { nodes { commit { committedDate statusCheckRollup { contexts(first: 100) {
        nodes { ... on CheckRun { name conclusion } ... on StatusContext { context state } }
      } } } } }
    }
  }
}'

# Prints "skip: <reason>", "wait: <reason>", "merge" or "dismiss <review id>".
decide='
  .headRefOid as $head
  | (.commits.nodes[0].commit) as $commit
  | ([.reviews.nodes[] | select(.author.login == "coderabbitai" and (.state == "APPROVED" or .state == "CHANGES_REQUESTED"))] | last) as $rabbit
  | ([.comments.nodes[] | select(.author.login == "chatgpt-codex-connector" and (.body | contains("Didn'"'"'t find any major issues")))]
     | last | .body // "" | [capture("Reviewed commit:\\*\\* `(?<sha>[0-9a-f]+)`")] | .[0].sha // "") as $codexSha
  | ([$commit.statusCheckRollup.contexts.nodes[]? | {name: (.name // .context), ok: ((.conclusion // .state) | IN("SUCCESS", "SKIPPED"))}]) as $checks
  | ([.comments.nodes[].createdAt, .reviews.nodes[].submittedAt, .reviewThreads.nodes[].comments.nodes[].createdAt, $commit.committedDate]
     | map(select(.) | fromdateiso8601) | max) as $lastActivity
  | if .state != "OPEN" then "skip: not open"
    elif .isDraft then "skip: draft"
    elif .isCrossRepository then "skip: fork head"
    elif .headRefName == "changeset-release/main" then "skip: release pull request"
    elif (.title | contains("[WIP]") or contains("[skip review]")) or any(.labels.nodes[]; .name == "do-not-review")
      then "skip: excluded from CodeRabbit review"
    elif .mergeable != "MERGEABLE" then "wait: not mergeable (\(.mergeable))"
    elif any($required[]; . as $name | [$checks[] | select(.name == $name)] | length == 0 or any(.ok | not))
      then "wait: required checks have not all passed"
    # ponytail: fail closed past one page of threads; paginate if PRs outgrow it.
    elif .reviewThreads.totalCount > 100 then "wait: too many review threads to verify"
    elif any(.reviewThreads.nodes[]; .isResolved | not) then "wait: unresolved review threads"
    elif all(.reactions.nodes[]; .user.login != "chatgpt-codex-connector[bot]") then "wait: no Codex 👍"
    elif $codexSha == "" or ($head | startswith($codexSha) | not) then "wait: Codex has not cleared the head commit"
    elif $rabbit == null then "wait: no CodeRabbit approval"
    elif $rabbit.state == "APPROVED" then "merge"
    elif $now - $lastActivity < 7200 then "wait: CodeRabbit requests changes and the PR was active in the last 2 hours"
    else "dismiss \($rabbit.databaseId)"
    end'

failed=0
for number in $numbers; do
  pr=$(gh api graphql -F owner="${repo%/*}" -F name="${repo#*/}" -F number="$number" -f query="$query" |
    jq '.data.repository.pullRequest')
  decision=$(jq -r --argjson required "$required" --argjson now "$now" "$decide" <<<"$pr")
  echo "#$number: $decision"
  [[ $decision == merge || $decision == dismiss* ]] || continue
  [[ -z ${DRY_RUN:-} ]] || continue
  if [[ $decision == dismiss* ]] &&
    ! gh api -X PUT "repos/$repo/pulls/$number/reviews/${decision#dismiss }/dismissals" \
      -f event=DISMISS \
      -f message='Stale: every CodeRabbit thread is resolved and the pull request has been quiet for 2 hours.' >/dev/null; then
    failed=1
    continue
  fi
  gh pr merge "$number" --repo "$repo" --squash --match-head-commit "$(jq -r .headRefOid <<<"$pr")" || failed=1
done
exit "$failed"
