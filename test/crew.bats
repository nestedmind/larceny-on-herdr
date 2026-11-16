#!/usr/bin/env bats

load test_helper
load loh_helper

setup() {
  make_workspace
  export LARCENY_CONFIG_DIR="$BATS_TEST_TMPDIR/larceny"
  mkdir -p "$LARCENY_CONFIG_DIR"
  LOH="$REPO_ROOT/bin/loh"
}

crew() { "$LOH" crew --json | jq -c "$1"; }

@test "crew with no config says the shipped names" {
  run "$LOH" crew --json
  [ "$status" -eq 0 ]
  [ "$output" = '{"coordinator":"Scofield","reviewer":"Amy","advisor":"Yoda","teacher":"Sara","coders":["Sucre","Mahone","Sheba","Whip"],"person":""}' ]
}

@test "crew takes the project's own values" {
  cat >>"$WS/api/.larceny/config.md" <<'MD'
coders: Mia, Ana, Bo, Cy
reviewer: Rex
advisor: Ada
teacher: Tom
person: Dana
MD
  [ "$(crew .coordinator)" = '"Mia"' ]
  [ "$(crew .coders)" = '["Ana","Bo","Cy"]' ]
  [ "$(crew .reviewer)" = '"Rex"' ]
  [ "$(crew .advisor)" = '"Ada"' ]
  [ "$(crew .teacher)" = '"Tom"' ]
  [ "$(crew .person)" = '"Dana"' ]
}

@test "crew: coders default keeps the shipped roster" {
  echo "coders: default" >>"$WS/api/.larceny/config.md"
  [ "$(crew .coordinator)" = '"Scofield"' ]
  [ "$(crew '.coders|length')" = 4 ]
}

@test "crew follows the global file with crew: global" {
  echo "crew: global" >>"$WS/api/.larceny/config.md"
  printf 'person: Ola\ncoders: Zed, Kit, Lou\nreviewer: Vic\n' >"$LARCENY_CONFIG_DIR/global-config.md"
  [ "$(crew .coordinator)" = '"Zed"' ]
  [ "$(crew .coders)" = '["Kit","Lou"]' ]
  [ "$(crew .reviewer)" = '"Vic"' ]
  [ "$(crew .person)" = '"Ola"' ]
  [ "$(crew .advisor)" = '"Yoda"' ]
}

@test "crew ignores the global file without crew: global" {
  printf 'person: Ola\nreviewer: Vic\n' >"$LARCENY_CONFIG_DIR/global-config.md"
  [ "$(crew .reviewer)" = '"Amy"' ]
  [ "$(crew .person)" = '""' ]
}

@test "crew: project's value beats the global one" {
  printf 'crew: global\nreviewer: Pat\n' >>"$WS/api/.larceny/config.md"
  printf 'reviewer: Vic\nteacher: Gus\n' >"$LARCENY_CONFIG_DIR/global-config.md"
  [ "$(crew .reviewer)" = '"Pat"' ]
  [ "$(crew .teacher)" = '"Gus"' ]
}

@test "crew with a missing global file falls back to defaults" {
  echo "crew: global" >>"$WS/api/.larceny/config.md"
  [ "$(crew .reviewer)" = '"Amy"' ]
}

@test "crew reads the global file fresh each time" {
  echo "crew: global" >>"$WS/api/.larceny/config.md"
  echo "reviewer: Vic" >"$LARCENY_CONFIG_DIR/global-config.md"
  [ "$(crew .reviewer)" = '"Vic"' ]
  echo "reviewer: Wen" >"$LARCENY_CONFIG_DIR/global-config.md"
  [ "$(crew .reviewer)" = '"Wen"' ]
}

@test "crew uses the first repo that sets a key" {
  cat >>"$WS/.loh/workspace.md" <<'MD'
  - name: web
    path: ./web
    branch: main
    github: acme/web
MD
  mkdir -p "$WS/web/.larceny"
  printf 'reviewer: Web\nperson: Eve\n' >"$WS/web/.larceny/config.md"
  printf 'reviewer: Api\n' >>"$WS/api/.larceny/config.md"
  [ "$(crew .reviewer)" = '"Api"' ]
  [ "$(crew .person)" = '"Eve"' ]
}

@test "crew refuses arguments" {
  run "$LOH" crew --bogus
  [ "$status" -eq 2 ]
}

@test "crew without --json prints one line per role" {
  echo "reviewer: Rex" >>"$WS/api/.larceny/config.md"
  run "$LOH" crew
  [ "$status" -eq 0 ]
  [[ "$output" == *"reviewer: Rex"* ]]
}
