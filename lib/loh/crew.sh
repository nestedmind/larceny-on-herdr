# shellcheck shell=bash
# loh crew [--json]: the crew's names, resolved the way larceny's
# docs/crew-resolution.md says: each repo's .larceny/config.md, then the global
# file for a repo that says `crew: global`, then the shipped names. Both are
# read fresh on every call.
#
# --json prints one object:
#   {"coordinator":..,"reviewer":..,"advisor":..,"teacher":..,
#    "coders":[..],"person":".."}
# `coders` is the roster in order without the coordinator (the first name of a
# custom `coders:` roster). `person` is the owner's name, "" when none is set.
# Names are as written in the config; a terminal's name is the lower-case form.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

json=""
case "${1:-}" in
  "") ;;
  --json) json=1 ;;
  *)
    echo "Usage: loh crew [--json]" >&2
    exit 2
    ;;
esac
[[ $# -le 1 ]] || {
  echo "Usage: loh crew [--json]" >&2
  exit 2
}

need jq
manifest_load
crew_load

if [[ -n "$json" ]]; then
  jq -cn --arg co "$CREW_COORDINATOR" --arg re "$CREW_REVIEWER" --arg ad "$CREW_ADVISOR" \
    --arg te "$CREW_TEACHER" --arg pe "$CREW_PERSON" '$ARGS.positional as $c
    | {coordinator: $co, reviewer: $re, advisor: $ad, teacher: $te, coders: $c, person: $pe}' \
    --args ${CREW_CODERS[@]+"${CREW_CODERS[@]}"}
else
  printf 'coordinator: %s\nreviewer: %s\nadvisor: %s\nteacher: %s\ncoders: %s\nperson: %s\n' \
    "$CREW_COORDINATOR" "$CREW_REVIEWER" "$CREW_ADVISOR" "$CREW_TEACHER" \
    "$(
      IFS=,
      echo "${CREW_CODERS[*]-}"
    )" "$CREW_PERSON"
fi
