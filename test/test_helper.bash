# Shared bats helpers.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
export REPO_ROOT

# Build a throwaway plugin tree in $PLUGIN_TREE: the real bin/loh and
# lib/loh/common.sh, a fixture plugin.json and one fixture command, so
# dispatch tests do not depend on which real commands exist.
make_plugin_tree() {
  PLUGIN_TREE="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$PLUGIN_TREE/bin" "$PLUGIN_TREE/lib/loh" "$PLUGIN_TREE/.claude-plugin"
  cp "$REPO_ROOT/bin/loh" "$PLUGIN_TREE/bin/loh"
  cp "$REPO_ROOT/lib/loh/common.sh" "$PLUGIN_TREE/lib/loh/common.sh"
  printf '{\n  "name": "fixture",\n  "version": "9.8.7"\n}\n' \
    >"$PLUGIN_TREE/.claude-plugin/plugin.json"
  cat >"$PLUGIN_TREE/lib/loh/hello.sh" <<'SH'
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
echo "hello $*"
SH
  LOH="$PLUGIN_TREE/bin/loh"
}

# Put the fake hc first on PATH and point its log at the test's temp dir.
use_fake_hc() {
  export FAKE_HC_LOG="$BATS_TEST_TMPDIR/hc.log"
  : >"$FAKE_HC_LOG"
  PATH="$REPO_ROOT/test/fakes:$PATH"
}

# Headless Chrome hygiene for the parity tests. Each test gets its own profile folder parent (PARITY_TMP) and a file
# (PARITY_PIDS) where chrome.mjs records the process group of every Chrome it starts. parity_teardown ends those groups,
# and only those, if the test left one running (bats interrupted, node killed). It never matches by name.
parity_setup() {
  export PARITY_TMP="$BATS_TEST_TMPDIR/parity-tmp" PARITY_PIDS="$BATS_TEST_TMPDIR/parity-pids"
  mkdir -p "$PARITY_TMP"
  : >"$PARITY_PIDS"
}

parity_teardown() {
  local pid
  [ -n "${PARITY_PIDS:-}" ] && [ -f "$PARITY_PIDS" ] || return 0
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
  done <"$PARITY_PIDS"
  [ -n "${PARITY_TMP:-}" ] && rm -rf "$PARITY_TMP"
}
