#!/usr/bin/env bats
# Walks through the doors only, and never a new way while someone is on their way: the pure parts of the office's motion.

bats_require_minimum_version 1.5.0
load test_helper

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

crew_js() {
  command -v node >/dev/null || skip "node not installed"
  cp "$(mod_dir)/crew.js" "$BATS_TEST_TMPDIR/crew.mjs"
  node --input-type=module -e "import * as crew from '$BATS_TEST_TMPDIR/crew.mjs'; $1"
}

# A change of place has to hold for GOAL_HOLD ms before the person sets off, and a walk that is on its
# way is never redirected: the next one starts after it ends. `run` plays one render's decision per event.
step_js='
const hold = crew.GOAL_HOLD;
const A = {x: 10, y: 10}, B = {x: 90, y: 40}, C = {x: 50, y: 50};
const run = (events) => { let pending = null, out = []; for (const [t, goal, walking] of events) { const r = crew.nextGoal(pending, A, goal, t, walking); pending = r.pending; out.push(r.go ? "go" : r.wakeIn === null ? "idle" : "wait" + r.wakeIn); } return out.join(" "); };
'

@test "a new place does not send anyone until it has held for the hold time" {
  run crew_js "$step_js"'console.log(hold, run([[0, B, false], [400, B, false], [hold - 1, B, false], [hold, B, false]]));'
  [ "$status" -eq 0 ]
  [ "$output" = "1000 wait1000 wait600 wait1 go" ]
}

@test "a place that flips back before the hold ends sends nobody anywhere" {
  run crew_js "$step_js"'console.log(run([[0, B, false], [500, A, false], [1600, A, false]]));'
  [ "$status" -eq 0 ]
  [ "$output" = "wait1000 idle idle" ]
}

@test "a flip to a third place restarts the hold" {
  run crew_js "$step_js"'console.log(run([[0, B, false], [800, C, false], [1700, C, false], [1800, C, false]]));'
  [ "$status" -eq 0 ]
  [ "$output" = "wait1000 wait1000 wait100 go" ]
}

@test "someone who is walking is never sent a new way, and goes when the walk ends" {
  run crew_js "$step_js"'console.log(run([[0, B, true], [1500, B, true], [9000, B, true], [9100, B, false]]));'
  [ "$status" -eq 0 ]
  [ "$output" = "wait1000 idle idle go" ]
}

# Wall check: sample a leg and see where it goes. A change between two regions is allowed only between a
# room and the corridor, at that room's door (the gap is 18 wide).
walls_js='
const reg = (w, p) => { const r = crew.roomAt(w, p.x, p.y); if (r) return r.key; return p.y >= w.corr.y && p.y <= w.corr.y + w.corr.h ? "corr" : null; };
const crossings = (w, a, b) => {
  let bad = 0, prev = reg(w, a), pp = a;
  const n = Math.max(2, Math.ceil(Math.hypot(b.x - a.x, b.y - a.y) / 0.5));
  for (let i = 1; i <= n; i++) {
    const p = {x: a.x + (b.x - a.x) * i / n, y: a.y + (b.y - a.y) * i / n}, r = reg(w, p);
    if (r !== prev) {
      const room = w.rooms.find((x) => x.key === (r === "corr" ? prev : r));
      if (!((r === "corr" || prev === "corr") && room && Math.abs(p.x - room.door) <= 9 && Math.abs(pp.x - room.door) <= 9)) bad++;
    }
    prev = r; pp = p;
  }
  return bad;
};
'

@test "from any point along a walk between any two places, no leg of the way on crosses a wall or outruns walking speed" {
  run crew_js "$walls_js"'
let legsSeen = 0, bad = 0, fast = 0;
for (const [repos, aspect] of [[["api", "web"], 1.2], [["a"], 0], [["a", "b", "c"], 2.5]]) {
  const w = crew.worldFor(repos, aspect);
  const places = [...w.desks.map((d) => d.seat), w.mattDesk.seat, w.bed, ...Object.values(w.meetSeats), ...Object.values(w.spots).flat()];
  for (const a of places) for (const b of places) {
    const whole = crew.legsOf(a, crew.pathTo(w, "q", a, b)), total = crew.walkMs(whole);
    for (let k = 0; k <= 4; k++) {
      const s = crew.posAt(a, whole, (total * k) / 4);
      for (const g of places) {
        let at = s;
        for (const l of crew.legsOf(s, crew.pathTo(w, "p" + k, s, g))) {
          legsSeen++; bad += crossings(w, at, l) ? 1 : 0;
          const d = Math.hypot(l.x - at.x, l.y - at.y);
          if (d / ((l.ms + 0.5) / 1000) > crew.WALK_SPEED + 0.001) fast++;
          at = l;
        }
      }
    }
  }
}
console.log(legsSeen > 100000, bad, fast);'
  [ "$status" -eq 0 ]
  [ "$output" = "true 0 0" ]
}

# What a room draws on someone (the kitchen's mug, the table's paddle and rally) follows where they stand, as the screens do,
# and not where the layout is sending them: the layout changes up to GOAL_HOLD before they set off.
@test "someone's mug and paddle stay as they were while they stand in the room they are leaving" {
  run crew_js '
const mug = { mug: true, paddle: 0, spot: null }, pong = { mug: false, paddle: 1, spot: "pong:0" };
const seen = crew.standLook(undefined, mug, true);
const held = crew.standLook(seen, pong, false);
const arrived = crew.standLook(held, pong, true);
console.log(JSON.stringify([seen, held, arrived]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[{"mug":true,"paddle":0,"spot":null},{"mug":true,"paddle":0,"spot":null},{"mug":false,"paddle":1,"spot":"pong:0"}]' ]
}

@test "the rally goes on while both players still stand at the table, and stops once one walks off" {
  run crew_js '
const at = (spot, walking) => ({ look: { spot }, walking });
console.log(crew.rallyOf([at("pong:0", false), at("pong:1", false), at(null, false)]), crew.rallyOf([at("pong:0", false), at("pong:1", true)]), crew.rallyOf([at("pong:0", false)]));'
  [ "$status" -eq 0 ]
  [ "$output" = "true false false" ]
}
