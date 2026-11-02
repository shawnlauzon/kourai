#!/bin/bash
# Prints a short-lived (1 hour) GitHub token for the installation's GitHub App (github.app_id),
# installed on the given repo. Agents use it so their pushes and PRs come from
# <github.bot_name>[bot] instead of the user, and the user can review them.
#
#   GH_TOKEN=$(gh-app-token.sh <owner/repo>) gh pr create ...
#
# Never prints the private key. Prints only the token, nothing else on stdout.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"

APP_ID=$(kc github.app_id)
KEY=$(kc github.app_key_file)
repo=${1:?usage: gh-app-token.sh <owner/repo>}
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$APP_ID" | b64url)
signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$KEY" | b64url)
jwt="$header.$payload.$signature"

# One retry after a pause (2 seconds) on a network error (curl exits non-zero), 429 or 5xx; never on 401, 403, 404 or
# another 4xx (rules.md, A transient failure). At most 2 tries per call. Prints the body on 2xx, returns 22 otherwise.
api() { # api <method> <path>
  local out rc code try
  for try in 1 2; do
    rc=0
    out=$(curl -s -w '\n%{http_code}' -X "$1" -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com$2") || rc=$?
    code=${out##*$'\n'}
    if [ "$rc" = 0 ] && [[ "$code" == 2?? ]]; then
      printf '%s\n' "${out%$'\n'*}"
      return 0
    fi
    if [ "$try" = 1 ] && { [ "$rc" != 0 ] || [ "$code" = 429 ] || [[ "$code" == 5?? ]]; }; then
      sleep "${GH_APP_TOKEN_RETRY_PAUSE:-2}"
      continue
    fi
    return 22
  done
}

# A repo that moved or was renamed (repos.*.legacy_slugs): the lookup below does not follow GitHub's redirect from
# the old name, so it is looked up under every name of that repo, the one given first.
names=("$repo")
while IFS= read -r other; do
  [ -n "$other" ] && [ "$other" != "$repo" ] && names+=("$other")
done < <(kourai-config json repos | jq -r --arg r "$repo" '.[] | select(.slug == $r or ((.legacy_slugs // []) | index($r) != null)) | ([.slug] + (.legacy_slugs // []))[]')
installation=""
for name in "${names[@]}"; do
  installation=$(api GET "/repos/$name/installation" 2>/dev/null | jq -r '.id // empty' 2>/dev/null) || installation=""
  [ -n "$installation" ] && break
done
[ -n "$installation" ] || { echo "gh-app-token: $(kc github.bot_name) isn't installed on $repo" >&2; exit 1; }
api POST "/app/installations/$installation/access_tokens" | jq -r .token
