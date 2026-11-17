#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper
load loh_helper

ABSENT='{}'
IDLE='{"state":"live","status":{"state":"idle"}}'
LIVE='{"state":"live","status":{"state":"idle"},"labels":{"crew":"shop"}}'

# make_repo <dir> <origin url or "none">: a real git repo with one commit.
make_repo() {
  local id=(-c user.name=t -c user.email=t@example.invalid)
  git init -q -b main "$1"
  echo hi >"$1/README"
  git -C "$1" add README
  git -C "$1" "${id[@]}" commit -q -m init
  if [[ "$2" != none ]]; then git -C "$1" remote add origin "$2"; fi
}

setup() {
  use_fake_hc_only
  use_hc_script
  export LOH_POLL=0.05 LOH_START_TIMEOUT=2
  unset LOH_WORKSPACE
  HOME_DIR="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME_DIR/code" "$BATS_TEST_TMPDIR/stubs"
  # gh stub: `gh repo view <slug> --json defaultBranchRef --jq ...` prints
  # $FAKE_GH_BRANCH (default main). Anything else is an error.
  export FAKE_GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : >"$FAKE_GH_LOG"
  cat >"$BATS_TEST_TMPDIR/stubs/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
if [[ "$1 $2" == "repo view" ]]; then printf '%s\n' "${FAKE_GH_BRANCH:-main}"; exit 0; fi
exit 1
SH
  chmod +x "$BATS_TEST_TMPDIR/stubs/gh"
  # herdr-app stub; a fresh log per test
  export FAKE_APP_LOG="$BATS_TEST_TMPDIR/app.log"
  : >"$FAKE_APP_LOG"
  ln -sf "$REPO_ROOT/test/fakes/herdr-app" "$BATS_TEST_TMPDIR/stubs/herdr-app"
  PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
  # A copy of the plugin without watch.sh, as up.bats does.
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/bin" "$TREE/lib/loh" "$TREE/.claude-plugin"
  cp "$REPO_ROOT/bin/loh" "$TREE/bin/loh"
  cp "$REPO_ROOT"/lib/loh/*.sh "$TREE/lib/loh/"
  cp -r "$REPO_ROOT/lib/loh/prompts" "$TREE/lib/loh/"
  rm -f "$TREE/lib/loh/watch.sh"
  cp "$REPO_ROOT/.claude-plugin/plugin.json" "$TREE/.claude-plugin/"
  LOH="$TREE/bin/loh"
  make_repo "$HOME_DIR/code/shop" "git@github.com:acme/shop.git"
  cd "$HOME_DIR/code/shop"
}

fresh_start() {
  hc_seq get.scofield "$ABSENT" "$IDLE"
  hc_seq get.amy "$ABSENT" "$IDLE"
}

@test "init makes a sibling workspace from the current repo and starts the crew" {
  fresh_start
  run "$LOH" init
  [ "$status" -eq 0 ]
  ws="$HOME_DIR/code/shop-crew"
  [ -f "$ws/.loh/workspace.md" ]
  run cat "$ws/.loh/workspace.md"
  [[ "$output" == *$'name: shop\npane_mode: auto\nrepos:\n  - name: shop\n    path: '"$HOME_DIR"$'/code/shop\n    branch: main\n    github: acme/shop'* ]]
  grep -q $'^run\t.*--name\tscofield' "$FAKE_HC_LOG"
  grep -q $'^run\t.*--name\tamy' "$FAKE_HC_LOG"
}

@test "init reads the default branch from gh and the slug from an https origin" {
  make_repo "$HOME_DIR/code/web" "https://github.com/acme/web-app.git"
  export FAKE_GH_BRANCH=trunk
  fresh_start
  run "$LOH" init "$HOME_DIR/code/web"
  [ "$status" -eq 0 ]
  run cat "$HOME_DIR/code/web-crew/.loh/workspace.md"
  [[ "$output" == *"    branch: trunk"* ]]
  [[ "$output" == *"    github: acme/web-app"* ]]
  [[ "$output" == *"  - name: web"* ]]
  grep -q 'repo view acme/web-app' "$FAKE_GH_LOG"
}

@test "init falls back to origin/HEAD when gh cannot say" {
  : >"$BATS_TEST_TMPDIR/stubs/gh"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/stubs/gh"
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  fresh_start
  run "$LOH" init
  [ "$status" -eq 0 ]
  grep -q "    branch: develop" "$HOME_DIR/code/shop-crew/.loh/workspace.md"
}

@test "init takes several repos for one new workspace named after the first" {
  make_repo "$HOME_DIR/code/web" "git@github.com:acme/web.git"
  fresh_start
  run "$LOH" init "$HOME_DIR/code/web" "$HOME_DIR/code/shop"
  [ "$status" -eq 0 ]
  run cat "$HOME_DIR/code/web-crew/.loh/workspace.md"
  [[ "$output" == *"name: web"* ]]
  [[ "$output" == *"  - name: web"* ]]
  [[ "$output" == *"  - name: shop"* ]]
}

@test "init refuses a repo with no GitHub origin and writes nothing" {
  make_repo "$HOME_DIR/code/local" none
  run --separate-stderr "$LOH" init "$HOME_DIR/code/local"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"local"*"no GitHub origin"* ]]
  [ ! -e "$HOME_DIR/code/local-crew" ]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
}

@test "init refuses an origin that is not on GitHub" {
  make_repo "$HOME_DIR/code/gl" "git@gitlab.com:acme/gl.git"
  run --separate-stderr "$LOH" init "$HOME_DIR/code/gl"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no GitHub origin"* ]]
}

@test "init refuses a folder that is not a git repo" {
  mkdir "$HOME_DIR/code/plain"
  run --separate-stderr "$LOH" init "$HOME_DIR/code/plain"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"not a git repo"* ]]
}

# An existing workspace for the add-a-repo tests.
existing_workspace() {
  WS="$BATS_TEST_TMPDIR/shared"
  mkdir -p "$WS/.loh"
  cat >"$WS/.loh/workspace.md" <<MD
# my crew
name: shop
pane_mode: plan
idle_minutes: 5
repos:
  - name: shop
    path: $HOME_DIR/code/shop
    branch: main
    github: acme/shop
board: later
MD
}

@test "init adds a new repo to an existing workspace and keeps the rest of the manifest" {
  existing_workspace
  make_repo "$HOME_DIR/code/web" "git@github.com:acme/web.git"
  hc_reply get.scofield "$LIVE"
  hc_reply get.amy "$LIVE"
  run "$LOH" init "$HOME_DIR/code/web" --workspace "$WS"
  [ "$status" -eq 0 ]
  run cat "$WS/.loh/workspace.md"
  [ "${lines[0]}" = "# my crew" ]
  [[ "$output" == *$'pane_mode: plan\nidle_minutes: 5\nrepos:\n  - name: shop\n'* ]]
  [[ "$output" == *$'    github: acme/shop\n  - name: web\n    path: '"$HOME_DIR"$'/code/web\n    branch: main\n    github: acme/web\nboard: later'* ]]
}

@test "init tells a live coordinator about the new repos and which lack a larceny config" {
  existing_workspace
  make_repo "$HOME_DIR/code/web" "git@github.com:acme/web.git"
  make_repo "$HOME_DIR/code/api" "git@github.com:acme/api.git"
  mkdir "$HOME_DIR/code/api/.larceny"
  : >"$HOME_DIR/code/api/.larceny/config.md"
  hc_reply get.scofield "$LIVE"
  hc_reply get.amy "$LIVE"
  run "$LOH" init "$HOME_DIR/code/web" "$HOME_DIR/code/api" --workspace "$WS"
  [ "$status" -eq 0 ]
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -q $'^send\t' "$FAKE_HC_LOG" && break
    sleep 0.25
  done
  msg="$(grep $'^send\t' "$FAKE_HC_LOG")"
  [[ "$msg" == *$'\tscofield\t'* ]]
  [[ "$msg" == *"web"* && "$msg" == *"api"* ]]
  [[ "$msg" == *"no .larceny/config.md yet, so onboard them: web."* ]]
}

@test "init says nothing was added and does not touch the manifest on a re-run" {
  fresh_start
  run "$LOH" init
  [ "$status" -eq 0 ]
  ws="$HOME_DIR/code/shop-crew"
  before="$(cat "$ws/.loh/workspace.md")"
  stat_before="$(stat -c %Y "$ws/.loh/workspace.md")"
  sleep 1.1
  : >"$FAKE_HC_LOG"
  rm -f "$FAKE_HC_SCRIPT"/get.* "$FAKE_HC_SCRIPT"/.count.*
  hc_reply get.scofield "$LIVE"
  hc_reply get.amy "$LIVE"
  run "$LOH" init
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing new"* ]]
  [ "$(cat "$ws/.loh/workspace.md")" = "$before" ]
  [ "$(stat -c %Y "$ws/.loh/workspace.md")" = "$stat_before" ]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
  ! grep -q $'^send\t' "$FAKE_HC_LOG"
}

@test "init leaves a repo that is listed by github alone, even from another path" {
  existing_workspace
  make_repo "$HOME_DIR/code/shop2" "https://github.com/Acme/Shop.git"
  hc_reply get.scofield "$LIVE"
  hc_reply get.amy "$LIVE"
  before="$(cat "$WS/.loh/workspace.md")"
  run "$LOH" init "$HOME_DIR/code/shop2" --workspace "$WS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing new"* ]]
  [ "$(cat "$WS/.loh/workspace.md")" = "$before" ]
}

@test "init refuses a new repo whose name clashes with a listed one" {
  existing_workspace
  mkdir -p "$HOME_DIR/other"
  make_repo "$HOME_DIR/other/shop" "git@github.com:someone/shop.git"
  before="$(cat "$WS/.loh/workspace.md")"
  run --separate-stderr "$LOH" init "$HOME_DIR/other/shop" --workspace "$WS"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"name 'shop' is already listed"* ]]
  [ "$(cat "$WS/.loh/workspace.md")" = "$before" ]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
}

@test "a manifest that fails the check is never moved into place" {
  existing_workspace
  # A top-level key after the repos that the parser would take as a repo field
  # is fine; an unknown key makes the whole manifest invalid. A broken
  # manifest to begin with must stay exactly as it was.
  printf 'bogus_key: 1\n' >>"$WS/.loh/workspace.md"
  make_repo "$HOME_DIR/code/web" "git@github.com:acme/web.git"
  before="$(cat "$WS/.loh/workspace.md")"
  run --separate-stderr "$LOH" init "$HOME_DIR/code/web" --workspace "$WS"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"bogus_key"* ]]
  [ "$(cat "$WS/.loh/workspace.md")" = "$before" ]
  [ -z "$(ls -A "$WS/.loh" | grep -v '^workspace.md$')" ]
}

@test "a new manifest that fails the check leaves no manifest and no temp file" {
  # A repo name the manifest cannot hold fails the parser's own check.
  make_repo "$HOME_DIR/code/odd name" "git@github.com:acme/odd.git"
  run --separate-stderr "$LOH" init "$HOME_DIR/code/odd name"
  [ "$status" -eq 1 ]
  [ ! -e "$HOME_DIR/code/odd name-crew/.loh/workspace.md" ]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
}

@test "init opens the office tab when herdr-app is up and no office is open" {
  fresh_start
  run "$LOH" init
  [ "$status" -eq 0 ]
  grep -q $'^do\ttab.new\t--name\toffice\t--mod\tcrew-office' "$FAKE_APP_LOG"
  grep -q "shop-crew" "$FAKE_APP_LOG"
}

@test "init only prints the open command when an office is already open" {
  ws="$HOME_DIR/code/shop-crew"
  mkdir -p "$ws/.loh"
  cat >"$ws/.loh/workspace.md" <<MD
name: shop
repos:
  - name: shop
    path: $HOME_DIR/code/shop
    branch: main
    github: acme/shop
MD
  date +%s >"$ws/.loh/office-open"
  hc_reply get.scofield "$LIVE"
  hc_reply get.amy "$LIVE"
  run "$LOH" init
  [ "$status" -eq 0 ]
  [[ "$output" == *"office is already open"* ]]
  ! grep -q $'^do\ttab.new' "$FAKE_APP_LOG"
}

@test "init prints the open command when herdr-app is not running" {
  export FAKE_APP_RUNNING=0
  fresh_start
  run "$LOH" init
  [ "$status" -eq 0 ]
  [[ "$output" == *"herdr-app do tab.new --name office --mod crew-office"* ]]
  ! grep -q $'^do\ttab.new' "$FAKE_APP_LOG"
}

@test "init never touches git config or ~/.claude" {
  export HOME="$HOME_DIR"
  fresh_start
  run "$LOH" init
  [ "$status" -eq 0 ]
  [ ! -e "$HOME_DIR/.claude" ]
  [ ! -e "$HOME_DIR/.gitconfig" ]
}

@test "init is listed in loh help" {
  run "$LOH" help
  [[ "$output" == *"  init"* ]]
}

@test "init rejects an unknown option" {
  run --separate-stderr "$LOH" init --bogus
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh init"* ]]
}
