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
