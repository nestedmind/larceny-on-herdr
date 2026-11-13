// The cases the office is measured in. To add one, add an entry here: a name, the repos, the stage (the area the
// floor is fitted into, in px) and the crew. compare.mjs runs every check on every case, so a new case needs no new code.
// To add a check, add a function to CHECKS in compare.mjs.

const S = (name, status, extra = {}) => ({ name, status, ...extra });

// One crew that puts someone in every kind of place: Scofield and Amy at their desks, coders at repo desks typing,
// done coders in the kitchen (ten of them, so the rest room is used too), an idle coder at ping pong, the rest of the
// cast (not running) in the lounge, Matt at his desk. Names beyond the cast stand in as extra coders.
const extras = Array.from({ length: 9 }, (_, i) => S("Zed" + (i + 1), "done", { repo: "api" }));
export const CREW = [
  S("scofield", "working", { role: "coordinator" }),
  S("amy", "working", { role: "reviewer" }),
  S("sucre", "working", { repo: "api" }),
  S("whip", "working", { repo: "web" }),
  S("sheba", "idle", { repo: "web" }),
  S("mahone", "done", { repo: "api" }),
  S("maya", "working", { role: "helper" }),
  S("opemipo", "idle", { role: "helper" }),
  S("yoda", "idle", { role: "advisor" }),
  S("sara", "idle", { role: "teacher" }),
  ...extras,
];

// The prototype's floor is 480 x 288 and has two repos (api, web). A stage whose aspect is the prototype's makes
// the office's floor the same size, so every position must match exactly. Other stages grow the rooms on purpose
// (crew.js worldFor): there a thing may sit anywhere its room's growth allows, and nowhere else.
export const CASES = [
  { name: "two-repos-native", repos: ["api", "web"], stage: { w: 976, h: 592 }, crew: CREW, strict: true, route: true },
  { name: "two-repos-16x9", repos: ["api", "web"], stage: { w: 1296, h: 738 }, crew: CREW },
  { name: "two-repos-narrow", repos: ["api", "web"], stage: { w: 520, h: 900 }, crew: CREW },
  { name: "six-repos", repos: ["api", "web", "app", "docs", "infra", "tools"], stage: { w: 1700, h: 800 }, crew: CREW.map((a) => (a.repo === "web" ? { ...a, repo: "docs" } : a)) },
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
