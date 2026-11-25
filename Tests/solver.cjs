const assert = require("node:assert/strict");
require("../web/solver.js");
const { solve } = globalThis.GridnoteSolve;
for (const [input, output] of [
  ["5x+4=3", "x = -0.2"],
  ["5X+4=3", "X = -0.2"],
  ["5y+4=3", "y = -0.2"],
  ["5⋅4", "20"],
  ["5·4", "20"],
  ["5 . 4", "20"],
  ["5.4 + 1", "6.4"],
  ["5 x 4", "20"],
  ["5x + 2·x = 14", "x = 2"],
  ["5 * +4 = 20", "True"],
  ["72 km/h to m/s", "20 m/s"],
  ["2.2 kΩ → Ω", "2200 Ω"],
  ["3 mA to uA", "3000 µA"],
  ["3 + 4 * 2", "11"],
  ["-2^2 + 5", "1"],
  ["(-2)^2", "4"],
  ["1 / 2 + 3 / 4", "1.25"],
  ["Solve for t: 2(t + 1) = 8", "t = 3"],
  ["x² - 5x + 6 = 0", "x = 2 or 3"],
  ["x^2 + 1 = 0", "No real roots"],
  ["2x = 2x", "All real values of x"],
  ["2x + 1 = 2x", "No solution"],
  ["0.1+0.2=0.3", "True"],
  ["8 ÷ 2 = ?", "4"],
  ["4*6 =", "24"],
  ["1e-12x = 1", "x = 1000000000000"],
])
  assert.equal(solve(input)?.answer, output, input);
for (const s of [
  "10 V to A",
  "1 / 0",
  "x / x = 1",
  "2 + unknown()",
  "2 = 3 = 4",
  "2 + alert(1)",
  "x^3 = 8",
])
  assert.equal(solve(s)?.answer ?? null, null, s);
assert.match(solve("return x*x;", true).answer, /returned value is x \* x/);
assert.equal(solve("console.log(3 + 4);", true).answer, "7");
assert.equal(solve("int n = 4 + 2;", true).answer, "n = 6");
assert.equal(solve("for (;;) {", true).answer, null);
assert.equal(solve("Which load consumes more power?").kind, "Question");
assert.equal(GridnoteSolve.readInk("5×+4=3"), "5x+4=3");
assert.equal(GridnoteSolve.readInk("5y+4=3"), "5y+4=3");
assert.equal(GridnoteSolve.readInk("5⋅4=20"), "5⋅4=20");
console.log(
  "PASS arithmetic precedence, real roots, degeneracies, partial snippets and unsupported inputs.",
);
