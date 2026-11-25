const assert = require("node:assert/strict");
require("../web/elements.js");
require("../web/solver.js");
require("../web/majors.js");
const { kits, bases, molarMass } = GridnoteKits;
assert.equal(GridnoteElements.length, 118);
assert.equal(molarMass("Ca(OH)₂"), "74.092 g/mol");
assert.equal(molarMass("H₂O"), "18.015 g/mol");
assert.match(molarMass("CuSO4·5H2O"), /^249\.6/);
assert.throws(() => molarMass("Og"));
assert.throws(() => molarMass("Ca(OH"));
assert.match(
  bases("123456789ABCDEF0123456789", "16"),
  /90144042682896311822508713865/,
);
assert.throws(() => bases("102", "2"));
const expected = {
  Chemistry: [null, "74.092 g/mol", "0.5 mol/L", "0.25 mol/L"],
  Physics: ["6 m/s", "6 N"],
  Medicine: ["400×", "left and right"],
  Mathematics: ["x = -0.2", "Hypotenuse   5"],
  "Electrical Engineering": ["0.012 A", "66.666667 Ω"],
  "Computer Science": ["Hex   FF", "0xFD"],
  "Mechanical Engineering": ["40 MPa", "0.2%"],
};
const additional = {
  Chemistry: ["1 mol", "103.93078 kPa"],
  Physics: ["9 J", "-6 kg·m/s", "58.86 J", "100 m/s"],
  Medicine: ["front", "surfaces", "pulmonary valve", "cell grows"],
  Mathematics: ["x = 2", "11", "sample SD 2", "28.274334"],
  "Electrical Engineering": ["8 V", "100 ms", "31.415927", "50 mJ"],
  "Mechanical Engineering": ["10 N·m", "2.5132741", "-20 N", "1.2 mm"],
  "Computer Science": ["0x30", "1048576 B", "1 1 → 1", "11 probes"],
};
for (const major of Object.keys(kits)) {
  expected[major].push(...additional[major]);
  assert.equal(kits[major].length, 6);
}
assert.equal(kits.None, undefined);
assert.throws(() =>
  kits.Mathematics.find((t) => t.name === "Linear system").calculate(
    1,
    1,
    1,
    2,
    2,
    2,
  ),
);
assert.throws(() =>
  kits.Mathematics.find((t) => t.name === "Statistics").calculate("1 apple"),
);
assert.throws(() =>
  kits["Computer Science"]
    .find((t) => t.name === "Bitwise")
    .calculate("-1", "OR", "2"),
);
for (const [major, tools] of Object.entries(kits))
  for (const [i, t] of tools.entries())
    if (t.calculate) {
      const value = t.calculate(...t.inputs.map((f) => f.value));
      assert(value.includes(expected[major][i]), major + " / " + value);
    }
console.log(
  "PASS all subject calculators, 118 elements, formula parsing, unsupported elements and exact integer bases.",
);
