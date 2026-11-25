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
for (const [major, tools] of Object.entries(kits))
  for (const [i, t] of tools.entries())
    if (t.calculate) {
      const value = t.calculate(...t.inputs.map((f) => f.value));
      assert(value.includes(expected[major][i]), major + " / " + value);
    }
console.log(
  "PASS all subject calculators, 118 elements, formula parsing, unsupported elements and exact integer bases.",
);
