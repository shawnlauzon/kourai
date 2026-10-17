#!/usr/bin/env bash
# bin/kourai-config: merging over defaults, validation, interpolation and
# the get / json / shell / check / path commands. Uses tests/fixtures/defaults.toml.
. "$(dirname "$0")/lib.sh"
require_fakes

KC="$KOURAI_ROOT/bin/kourai-config"
export KOURAI_DEFAULTS="$KOURAI_ROOT/tests/fixtures/defaults.toml"
tmp=$(new_tmp)

minimal() {
  cat > "$1" <<'EOF'
[project]
name = "demo"

[board]
id = "AbCd1234"
EOF
}

# run <args...>: sets OUT (stdout+stderr) and RC
run() { OUT=$("$KC" "$@" 2>&1); RC=$?; }

# --- no config ---
unset KOURAI_CONFIG
run get limits.card_test_servers
assert_eq "no config exits 3" 3 "$RC"
assert_contains "no config says so" "NO CONFIG" "$OUT"

run --config "$tmp/missing.toml" check
assert_eq "missing file exits 3" 3 "$RC"
assert_contains "missing file named" "$tmp/missing.toml" "$OUT"

# --- a minimal valid config ---
minimal "$tmp/ok.toml"
export KOURAI_CONFIG="$tmp/ok.toml"
run check
assert_eq "minimal config is valid" 0 "$RC"
assert_eq "check prints CONFIG OK" "CONFIG OK: $tmp/ok.toml" "$OUT"

run path
assert_eq "path prints the config path" "$tmp/ok.toml" "$OUT"

run get limits.card_test_servers
assert_eq "default applies" "3" "$OUT"

run get limits.token_audit
assert_eq "bool prints lowercase" "true" "$OUT"

run get board.list_words
assert_eq "array prints one per line" "$(printf 'TODO\nDONE')" "$OUT"

run get board.credentials_file
assert_eq "interpolation and ~ expansion" "$HOME/kourai-state/trello.env" "$OUT"

run get project
assert_eq "a table prints as JSON" "demo" "$(printf '%s' "$OUT" | jq -r .name)"

run get limits.no_such_key
assert_eq "unknown key on get exits 2" 2 "$RC"
assert_contains "unknown key named" "limits.no_such_key" "$OUT"

run json
assert_eq "json is the merged config" "150000" "$(printf '%s' "$OUT" | jq -r .limits.context_ceiling_tokens)"
assert_eq "json leaves out _schema" "null" "$(printf '%s' "$OUT" | jq -r ._schema)"

# --- overrides ---
minimal "$tmp/over.toml"
cat >> "$tmp/over.toml" <<'EOF'

[limits]
card_test_servers = 5
EOF
run --config "$tmp/over.toml" get limits.card_test_servers
assert_eq "--config beats KOURAI_CONFIG, value overrides default" "5" "$OUT"
run --config "$tmp/over.toml" get limits.context_ceiling_tokens
assert_eq "sibling keys keep their defaults" "150000" "$OUT"

# Hot reload: every call reads the file again.
sed -i '' 's/card_test_servers = 5/card_test_servers = 4/' "$tmp/over.toml"
run --config "$tmp/over.toml" get limits.card_test_servers
assert_eq "a changed file applies on the next call" "4" "$OUT"

# State dir override flows into interpolated values.
minimal "$tmp/state.toml"
sed -i '' 's#name = "demo"#name = "demo"\nstate_dir = "/srv/my state"#' "$tmp/state.toml"
run --config "$tmp/state.toml" get board.credentials_file
assert_eq "interpolation uses the override" "/srv/my state/trello.env" "$OUT"

# --- shell output ---
run --config "$tmp/state.toml" shell
assert_contains "shell has scalars" "KOURAI_LIMITS_CARD_TEST_SERVERS=3" "$OUT"
eval_out=$(eval "$OUT"; printf '%s' "$KOURAI_BOARD_CREDENTIALS_FILE")
assert_eq "shell output evaluates with spaces intact" "/srv/my state/trello.env" "$eval_out"
assert_contains "dashes become underscores" "KOURAI_MODELS_BOARD_WATCHER=sonnet" "$OUT"

# --- validation failures ---
minimal "$tmp/typo.toml"
printf '\n[limits]\ncard_test_server = 5\n' >> "$tmp/typo.toml"
run --config "$tmp/typo.toml" check
assert_eq "unknown key is invalid" 1 "$RC"
assert_contains "names the unknown key" "limits.card_test_server" "$OUT"
assert_contains "starts with CONFIG INVALID" "CONFIG INVALID: $tmp/typo.toml" "$OUT"

run --config "$tmp/typo.toml" get project.name
assert_eq "get on an invalid config fails too" 1 "$RC"

minimal "$tmp/type.toml"
printf '\n[limits]\ncard_test_servers = "5"\n' >> "$tmp/type.toml"
run --config "$tmp/type.toml" check
assert_eq "string for an integer is invalid" 1 "$RC"
assert_contains "names the key and types" "limits.card_test_servers: expected integer, got string" "$OUT"

minimal "$tmp/bool.toml"
printf '\n[limits]\ncard_test_servers = true\n' >> "$tmp/bool.toml"
run --config "$tmp/bool.toml" check
assert_eq "bool for an integer is invalid" 1 "$RC"

minimal "$tmp/arr.toml"
printf '\n[board]\n' > /dev/null
sed -i '' 's/id = "AbCd1234"/id = "AbCd1234"\nlist_words = ["TODO", 3]/' "$tmp/arr.toml"
run --config "$tmp/arr.toml" check
assert_eq "wrong array element type is invalid" 1 "$RC"
assert_contains "names the element" "board.list_words[1]" "$OUT"

cat > "$tmp/req.toml" <<'EOF'
[project]
name = "demo"
EOF
run --config "$tmp/req.toml" check
assert_eq "missing required key is invalid" 1 "$RC"
assert_contains "names the required key" "board.id: required" "$OUT"

minimal "$tmp/ref.toml"
sed -i '' 's/name = "demo"/name = "demo"\nstate_dir = "{project.nope}\/x"/' "$tmp/ref.toml"
run --config "$tmp/ref.toml" check
assert_eq "unknown reference is invalid" 1 "$RC"
assert_contains "names the reference" "{project.nope}" "$OUT"

minimal "$tmp/schema.toml"
printf '\n[_schema]\nversion = 2\n' >> "$tmp/schema.toml"
run --config "$tmp/schema.toml" check
assert_eq "_schema in a config is invalid" 1 "$RC"

printf '[project\nname = 1\n' > "$tmp/syntax.toml"
run --config "$tmp/syntax.toml" check
assert_eq "TOML syntax error is invalid" 1 "$RC"
assert_contains "syntax error reported" "CONFIG INVALID" "$OUT"

# --- open tables ---
minimal "$tmp/models.toml"
printf '\n[models]\nmobile-builder = "opus"\n' >> "$tmp/models.toml"
run --config "$tmp/models.toml" get models.mobile-builder
assert_eq "open table takes new keys" "opus" "$OUT"
run --config "$tmp/models.toml" get models.board-watcher
assert_eq "open table keeps defaults" "sonnet" "$OUT"

# --- arrays of tables with item defaults ---
minimal "$tmp/repos.toml"
cat > "$tmp/repos.toml" <<'EOF'
repos = [
  { id = "server", slug = "org/server", base = "development" },
  { id = "app", slug = "org/app" },
]

[project]
name = "demo"

[board]
id = "AbCd1234"
EOF
run --config "$tmp/repos.toml" get repos.1.base
assert_eq "item defaults apply" "main" "$OUT"
run --config "$tmp/repos.toml" get repos.0.base
assert_eq "item value overrides" "development" "$OUT"
run --config "$tmp/repos.toml" get repos.1.free_paths
assert_eq "item array default" "docs/" "$OUT"
run --config "$tmp/repos.toml" get repos.2.base
assert_eq "index past the end exits 2" 2 "$RC"

sed -i '' 's/{ id = "app", slug = "org\/app" }/{ id = "app" }/' "$tmp/repos.toml"
run --config "$tmp/repos.toml" check
assert_eq "item missing a required key is invalid" 1 "$RC"
assert_contains "names the item key" "repos[1].slug: required" "$OUT"

sed -i '' 's/{ id = "app" }/{ id = "app", slug = "org\/app", bse = "main" }/' "$tmp/repos.toml"
run --config "$tmp/repos.toml" check
assert_eq "item unknown key is invalid" 1 "$RC"
assert_contains "names the item unknown key" "repos[1].bse" "$OUT"

# --- usage ---
run --config "$tmp/ok.toml" frobnicate
assert_eq "unknown command exits 2" 2 "$RC"

rm -rf "$tmp"
finish
