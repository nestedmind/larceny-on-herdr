// The cases the office is measured in. To add one, add an entry here: a name, the repos, the stage (the area the
// floor is fitted into, in px) and the crew. compare.mjs runs every check on every case, so a new case needs no new code.
// To add a check, add a function to CHECKS in compare.mjs.

const S = (name, status, extra = {}) => ({ name, status, ...extra });

// One crew that puts someone in every kind of place: Scofield and Amy at their desks, coders at repo desks typing,
// coders waiting on a review in the kitchen (six of them), four compacting in the rest room, an escalated coder at ping
// pong, Matt at his desk. Names beyond the cast stand in as extra coders. A coder with a PR and no work in hand is waiting
// on its review (the prototype's waitReview); one whose PR is at round 5 is with Matt (escalated); `ctx` is what the status
// hooks write while the context changes.
const extras = Array.from({ length: 9 }, (_, i) => (i < 5 ? S("Zed" + (i + 1), "done", { repo: "api", pr: String(10 + i), round: "1" }) : S("Zed" + (i + 1), "working", { repo: "api", ctx: "compact" })));
export const CREW = [
  S("scofield", "working", { role: "coordinator" }),
  S("amy", "working", { role: "reviewer" }),
  S("sucre", "working", { repo: "api" }),
  S("whip", "working", { repo: "web" }),
  S("sheba", "idle", { repo: "web", pr: "5", round: "5" }),
  S("mahone", "done", { repo: "api", pr: "6", round: "1" }),
  S("maya", "working", { role: "helper" }),
  S("opemipo", "idle", { role: "helper" }),
  S("yoda", "idle", { role: "advisor" }),
  S("sara", "idle", { role: "teacher" }),
  ...extras,
];

// The id the office gives each person: the cast id for a name in the cast, else "x:" and the terminal's address (t<index>).
const CAST_IDS = ["scofield", "sucre", "mahone", "sheba", "whip", "amy", "maya", "opemipo", "yoda", "sara"];
const idOf = (crew, i) => (CAST_IDS.includes(crew[i].name) ? crew[i].name : "x:t" + i);

// What the prototype's state machine calls each person's state, by name (the key is the name; extras by their name too).
// compare.mjs (states) maps it to a room through the prototype's own PLACE_OF_THEN and checks the office put them there.
const expectFor = (crew, states) => Object.fromEntries([["matt", states.matt || "matt"], ...crew.map((a, i) => [idOf(crew, i), states[a.name]]).filter(([, s]) => s)]);
const BASE_STATES = { scofield: "working", amy: "working", sucre: "working", whip: "working", sheba: "escalated", mahone: "waitReview", maya: "working", opemipo: "desk", yoda: "meeting", sara: "meeting",
  ...Object.fromEntries(extras.map((e, i) => [e.name, i < 5 ? "waitReview" : "resting"])) };

// The prototype's floor is 480 x 288 and has two repos (api, web). A stage whose aspect is the prototype's makes
// the office's floor the same size, so every position must match exactly. Other stages grow the rooms on purpose
// (crew.js worldFor): there a thing may sit anywhere its room's growth allows, and nowhere else.
const NATIVE = { w: 976, h: 592 };
const base = (name, crew, states, extra = {}) => ({ name, repos: ["api", "web"], stage: NATIVE, crew, typing: true, strict: true, expect: expectFor(crew, states), skip: ["tags"], ...extra });

// The seated and room states of ticket #26. A turn that has ended, less than the idle time ago (a minute), and then past it
// (3 minutes and a little); a coder with a PR and nothing to do waiting in the kitchen, then at ping pong (the prototype's
// tick: waitReview goes to pingpong after 15 s); an escalated coder; compacting and clearing; Matt away. Each person is
// checked against the prototype's room for the state in the table, and at a seat or spot it has there.
const TURN_ENDED = [
  S("scofield", "done", { role: "coordinator" }), S("amy", "idle", { role: "reviewer" }), S("yoda", "done", { role: "advisor" }), S("sara", "idle", { role: "teacher" }),
  S("sucre", "done", { repo: "api" }), S("whip", "idle", { repo: "web" }), S("Zed1", "idle", {}),
];
const WAITING = [S("sucre", "done", { repo: "api", pr: "3", round: "1" }), S("whip", "idle", { repo: "web", pr: "4", round: "2" })];

export const CASES = [
  { name: "two-repos-native", repos: ["api", "web"], stage: { w: 976, h: 592 }, crew: CREW, typing: true, expect: expectFor(CREW, BASE_STATES), strict: true, route: true },
  { name: "two-repos-16x9", repos: ["api", "web"], stage: { w: 1296, h: 738 }, crew: CREW, typing: true, expect: expectFor(CREW, BASE_STATES) },
  { name: "two-repos-narrow", repos: ["api", "web"], stage: { w: 520, h: 900 }, crew: CREW, typing: true, expect: expectFor(CREW, BASE_STATES) },
  { name: "six-repos", repos: ["api", "web", "app", "docs", "infra", "tools"], stage: { w: 1700, h: 800 }, crew: CREW.map((a) => (a.repo === "web" ? { ...a, repo: "docs" } : a)), typing: true, expect: expectFor(CREW, BASE_STATES) },
  base("seated-after-turn", TURN_ENDED, { scofield: "desk", amy: "desk", yoda: "meeting", sara: "meeting", sucre: "working", whip: "working", Zed1: "working" }, { advance: 60000 }),
  base("idle-3-minutes", TURN_ENDED, { scofield: "lounge", amy: "lounge", yoda: "lounge", sara: "lounge", sucre: "working", whip: "working", Zed1: "lounge" }, { advance: 190000 }),
  base("waiting-on-review", WAITING, { sucre: "waitReview", whip: "waitReview" }, { advance: 5000 }),
  base("ping-pong-after-15s", WAITING, { sucre: "pingpong", whip: "pingpong" }, { advance: 20000 }),
  base("escalated-to-matt", [S("sheba", "idle", { repo: "web", pr: "5", round: "5" }), S("sucre", "done", { repo: "api", pr: "3", round: "1" })], { sheba: "escalated", sucre: "waitReview" }),
  base("rest-room-and-away", [S("sheba", "working", { repo: "web", ctx: "compact" }), S("mahone", "idle", { repo: "api", pr: "6", round: "1", ctx: "clear" }), S("sucre", "working", { repo: "api" })],
    { sheba: "resting", mahone: "lounge", sucre: "working", matt: "away" }, { typing: false, advance: 6000 }),
];

// The walk checked on cases with `route`: from a kitchen spot to the leads room's desk seat.
export const ROUTE = { id: "mahone", from: { room: "kitchen", spot: 0 }, to: { desk: "scofield" }, samples: 24 };

// Where the office differs from the prototype and a ticket is open for it. Each entry names the case, the check, the
// person (or tag), the field and by how many px the office is off (to 0.1 px); a difference that matches all of them is
// printed as "known (<ticket>)" and does not fail the run. Anything else fails, so a known difference that gets worse
// fails too. An entry that matches nothing (the office was fixed, or its number moved) fails the run until it is
// removed or updated. Empty this list as the ticket lands.
// #29: name tags are stacked and clamped as the prototype does (a gap of 0.6 units, kept 2 units inside the floor's
// edges, pulled back inside its bottom edge).
const known = (kase, list) => list.map(([id, field, off]) => ({ case: kase, check: "tags", id, field, off, ticket: "#29" }));
export const KNOWN = [
  ...known("two-repos-native", [["sara", "x", 2], ["x:t15", "x", 2], ["x:t17", "x", 2], ["x:t10", "y", 17.03], ["x:t11", "y", 57.03], ["x:t17", "y", 29.01], ["x:t13", "y", 97.03], ["dog", "y", 3]]),
  ...known("two-repos-16x9", [["x:t13", "y", 1.29]]),
  ...known("two-repos-narrow", [["x:t10", "y", 1.11], ["x:t11", "y", 1.48], ["x:t17", "y", 1.11], ["x:t13", "y", 35.21]]),
  ...known("six-repos", [["sara", "x", 1.12], ["x:t11", "y", 13.87], ["x:t13", "y", 53.87]]),
];
