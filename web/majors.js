(function (global) {
  const show = (n) => {
    if (!Number.isFinite(n)) throw Error("Result exceeds the supported range.");
    return Number(n.toPrecision(8)).toString();
  };
  const positive = (n) => {
    if (n <= 0) throw Error("Enter a value greater than zero.");
    return n;
  };
  const nonnegative = (n) => {
    if (n < 0) throw Error("Enter a nonnegative value.");
    return n;
  };
  const fields = (name, relation, inputs, calculate) => ({
    name,
    relation,
    inputs,
    calculate,
  });
  const num = (label, value) => ({ label, value, type: "number" });
  const text = (label, value) => ({ label, value, type: "text" });
  const choice = (label, values) => ({ label, value: values[0], values });
  function molarMass(value) {
    const s = value
      .trim()
      .replace(/[₀-₉]/g, (c) => String("₀₁₂₃₄₅₆₇₈₉".indexOf(c)));
    if (s.length > 120 || !s) throw Error("Enter a chemical formula.");
    const weights = new Map(
      global.GridnoteElements.map((e) => [e[1], parseFloat(e[3])]),
    );
    const parts = s.split("·");
    let total = 0;
    for (const part of parts) {
      const tokens = part.match(/[A-Z][a-z]?|\d+|[()]/g) || [];
      if (tokens.join("") !== part || !tokens.length)
        throw Error("Use element symbols, parentheses and integer counts.");
      let i = 0;
      function count() {
        if (!/^\d+$/.test(tokens[i] || "")) return 1;
        const n = Number(tokens[i++]);
        if (!Number.isSafeInteger(n) || n < 1)
          throw Error("Use positive integer counts.");
        return n;
      }
      function group(nested) {
        let sum = 0,
          items = 0;
        while (i < tokens.length && tokens[i] !== ")") {
          const t = tokens[i++];
          let mass;
          if (t === "(") {
            mass = group(true);
            if (tokens[i++] !== ")") throw Error("Close the parenthesis.");
          } else {
            mass = weights.get(t);
            if (mass === undefined)
              throw Error("Unknown element or invalid formula.");
            if (!Number.isFinite(mass))
              throw Error("This element has no standard atomic weight.");
          }
          sum += mass * count();
          items++;
        }
        if (!items || (!nested && i !== tokens.length))
          throw Error("Check the formula and parentheses.");
        return sum;
      }
      const multiplier = count();
      total += multiplier * group(false);
    }
    return show(total) + " g/mol";
  }
  function bases(value, base) {
    const s = value.trim(),
      sign = s.startsWith("-") ? -1n : 1n,
      digits = s.replace(/^[+-]/, "").toUpperCase(),
      b = Number(base);
    if (![2, 8, 10, 16].includes(b) || !digits || digits.length > 256)
      throw Error("Enter 1–256 digits in the selected base.");
    let n = 0n;
    for (const ch of digits) {
      const digit = "0123456789ABCDEF".indexOf(ch);
      if (digit < 0 || digit >= b)
        throw Error("Digit outside the selected base.");
      n = n * BigInt(b) + BigInt(digit);
    }
    n *= sign;
    return [
      [2, "Binary"],
      [8, "Octal"],
      [10, "Decimal"],
      [16, "Hex"],
    ]
      .map(([radix, label]) => label + "   " + n.toString(radix).toUpperCase())
      .join("\n");
  }
  const kits = {
    Chemistry: [
      { name: "Periodic table", periodic: true },
      fields(
        "Molar mass",
        "Sum of abridged atomic weights",
        [text("Formula", "Ca(OH)2")],
        molarMass,
      ),
      fields(
        "Molarity",
        "c = n / V",
        [num("Amount (mol)", 0.25), num("Solution volume (L)", 0.5)],
        (n, v) => show(nonnegative(n) / positive(v)) + " mol/L",
      ),
      fields(
        "Dilution",
        "c₁V₁ = c₂V₂",
        [
          num("Stock (mol/L)", 1),
          num("Aliquot (mL)", 25),
          num("Final volume (mL)", 100),
        ],
        (c, v, w) => {
          if (positive(w) < positive(v))
            throw Error("Final volume must include the original aliquot.");
          return show((nonnegative(c) * v) / w) + " mol/L";
        },
      ),
    ],
    Physics: [
      fields(
        "Constant acceleration",
        "v = u + at     Δx = ut + ½at²",
        [
          num("Initial velocity (m/s)", 0),
          num("Acceleration (m/s²)", 2),
          num("Time (s)", 3),
        ],
        (u, a, t) => {
          nonnegative(t);
          return (
            "Final velocity   " +
            show(u + a * t) +
            " m/s\nDisplacement   " +
            show(u * t + 0.5 * a * t * t) +
            " m"
          );
        },
      ),
      fields(
        "Net force",
        "ΣF = ma",
        [num("Mass (kg)", 2), num("Acceleration (m/s²)", 3)],
        (m, a) => show(positive(m) * a) + " N",
      ),
    ],
    Medicine: [
      fields(
        "Microscope",
        "M = eyepiece × objective",
        [num("Eyepiece (×)", 10), num("Objective (×)", 40)],
        (a, b) => show(positive(a) * positive(b)) + "× total magnification",
      ),
      fields(
        "Anatomical planes",
        "Study reference in anatomical position",
        [choice("Plane", ["Sagittal", "Midsagittal", "Frontal", "Transverse"])],
        (p) =>
          ({
            Sagittal: "Divides the body into left and right portions.",
            Midsagittal: "Divides the body into equal left and right halves.",
            Frontal: "Divides the body into anterior and posterior portions.",
            Transverse: "Divides the body into superior and inferior portions.",
          })[p],
      ),
    ],
    Mathematics: [
      fields(
        "Equation",
        "One unknown, real linear and quadratic equations",
        [text("Equation", "5x + 4 = 3")],
        (s) => {
          const r = global.GridnoteSolve.solve(s);
          if (r?.kind !== "Equation" || r.answer == null)
            throw Error("Enter a supported equation.");
          return r.answer;
        },
      ),
      fields(
        "Right triangle",
        "c² = a² + b²",
        [num("Leg a", 3), num("Leg b", 4)],
        (a, b) =>
          "Hypotenuse   " +
          show(Math.hypot(positive(a), positive(b))) +
          "\nArea   " +
          show((a * b) / 2) +
          " square units",
      ),
    ],
    "Electrical Engineering": [
      fields(
        "Ohm’s law",
        "I = V/R     P = VI",
        [num("Voltage (V)", 12), num("Resistance (Ω)", 1000)],
        (v, r) =>
          "Current   " +
          show(v / positive(r)) +
          " A\nPower dissipated   " +
          show((v * v) / r) +
          " W",
      ),
      fields(
        "Resistor pair",
        "Series and parallel equivalent resistance",
        [num("R₁ (Ω)", 100), num("R₂ (Ω)", 200)],
        (a, b) => {
          nonnegative(a);
          nonnegative(b);
          return (
            "Series   " +
            show(a + b) +
            " Ω\nParallel   " +
            show(a === 0 || b === 0 ? 0 : 1 / (1 / a + 1 / b)) +
            " Ω"
          );
        },
      ),
    ],
    "Computer Science": [
      fields(
        "Number bases",
        "Exact signed integer conversion",
        [choice("Input base", ["10", "2", "8", "16"]), text("Value", "255")],
        (b, n) => bases(n, b),
      ),
      fields(
        "Two’s complement",
        "Fixed-width signed integer encoding",
        [choice("Bits", ["8", "16", "32", "64"]), text("Signed decimal", "-3")],
        (bits, input) => {
          if (!/^[+-]?\d{1,22}$/.test(input.trim()))
            throw Error("Enter a signed decimal integer.");
          const n = BigInt(input),
            b = BigInt(bits),
            limit = 1n << (b - 1n);
          if (n < -limit || n >= limit)
            throw Error("Outside the signed " + bits + "-bit range.");
          const u = BigInt.asUintN(Number(bits), n);
          return (
            u.toString(2).padStart(Number(bits), "0") +
            "\n0x" +
            u
              .toString(16)
              .toUpperCase()
              .padStart(Number(bits) / 4, "0")
          );
        },
      ),
    ],
    "Mechanical Engineering": [
      fields(
        "Axial stress",
        "σ = F/A     1 N/mm² = 1 MPa",
        [num("Axial force (N)", 1200), num("Area (mm²)", 30)],
        (f, a) => show(f / positive(a)) + " MPa",
      ),
      fields(
        "Normal strain",
        "ε = ΔL/L₀",
        [num("Change in length (mm)", 0.2), num("Original length (mm)", 100)],
        (d, l) => {
          positive(l);
          if (l + d <= 0) throw Error("Final length must be positive.");
          return show(d / l) + " strain\n" + show((100 * d) / l) + "%";
        },
      ),
    ],
  };
  global.GridnoteKits = { kits, molarMass, bases };
})(globalThis);
