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
  function reference(name, relation, label, entries) {
    return fields(
      name,
      relation,
      [choice(label, Object.keys(entries))],
      (key) => entries[key],
    );
  }
  kits.Chemistry.push(
    fields(
      "Mass to moles",
      "n = m / M",
      [num("Mass (g)", 18.015), num("Molar mass (g/mol)", 18.015)],
      (m, M) => show(nonnegative(m) / positive(M)) + " mol",
    ),
    fields(
      "Ideal gas",
      "PV = nRT · ideal gas, absolute temperature",
      [
        num("Amount (mol)", 1),
        num("Temperature (K)", 300),
        num("Volume (L)", 24),
      ],
      (n, T, V) =>
        show((nonnegative(n) * 8.314462618 * positive(T)) / positive(V)) +
        " kPa",
    ),
  );
  kits.Physics.push(
    fields(
      "Kinetic energy",
      "K = ½mv²",
      [num("Mass (kg)", 2), num("Speed (m/s)", 3)],
      (m, v) => show(0.5 * positive(m) * nonnegative(v) ** 2) + " J",
    ),
    fields(
      "Momentum",
      "p = mv · one dimension",
      [num("Mass (kg)", 2), num("Velocity (m/s)", -3)],
      (m, v) => show(positive(m) * v) + " kg·m/s",
    ),
    fields(
      "Gravity",
      "ΔU = mgΔh · uniform field",
      [
        num("Mass (kg)", 2),
        num("Height change (m)", 3),
        num("Gravity (m/s²)", 9.81),
      ],
      (m, h, g) => show(positive(m) * nonnegative(g) * h) + " J",
    ),
    fields(
      "Waves",
      "v = fλ     T = 1/f",
      [num("Frequency (Hz)", 50), num("Wavelength (m)", 2)],
      (f, l) =>
        show(positive(f) * positive(l)) + " m/s · period " + show(1 / f) + " s",
    ),
  );
  kits.Medicine.push(
    reference("Direction terms", "Anatomical position", "Direction", {
      Anterior: "Toward the front of the body.",
      Posterior: "Toward the back of the body.",
      Superior: "Toward the head.",
      Inferior: "Toward the feet.",
      Medial: "Toward the midline.",
      Lateral: "Away from the midline.",
      Proximal: "Nearer the attachment of a limb.",
      Distal: "Farther from the attachment of a limb.",
    }),
    reference("Tissue types", "Four primary tissue classes", "Class", {
      Epithelial: "Covers surfaces and lines cavities. Example: the epidermis.",
      Connective:
        "Supports, binds or transports. Examples: bone, cartilage and blood.",
      Muscle:
        "Contracts to generate force. Types: skeletal, cardiac and smooth.",
      Nervous:
        "Transmits and processes signals. Includes neurons and supporting glial cells.",
    }),
    reference(
      "Blood flow",
      "Follow the circulation through the heart",
      "Path",
      {
        Pulmonary:
          "Right ventricle → pulmonary valve → pulmonary trunk and arteries → lung capillaries → pulmonary veins → left atrium.",
        Systemic:
          "Left ventricle → aortic valve → aorta → systemic arteries → capillaries → systemic veins → venae cavae → right atrium.",
        Valves:
          "Right atrium → tricuspid valve → right ventricle. Left atrium → mitral valve → left ventricle.",
      },
    ),
    reference("Cell cycle", "Stages of a dividing somatic cell", "Stage", {
      G1: "The cell grows, makes proteins and organelles, and prepares for DNA synthesis.",
      S: "DNA is replicated. Each duplicated chromosome has two sister chromatids.",
      G2: "The cell prepares for mitosis and checks replicated DNA.",
      M: "Mitosis separates the chromosomes. Cytokinesis divides the cytoplasm.",
    }),
  );
  kits.Mathematics.push(
    fields(
      "Linear system",
      "ax + by = c     dx + ey = f",
      ["a", "b", "c", "d", "e", "f"].map((v, i) =>
        num(v, [2, 1, 5, 1, -1, 1][i]),
      ),
      (a, b, c, d, e, f) => {
        const det = a * e - b * d;
        if (det === 0) throw Error("The system has no unique solution.");
        return (
          "x = " +
          show((c * e - b * f) / det) +
          " · y = " +
          show((a * f - c * d) / det)
        );
      },
    ),
    fields(
      "Dot product",
      "u·v = uₓvₓ + uᵧvᵧ",
      [num("uₓ", 1), num("uᵧ", 2), num("vₓ", 3), num("vᵧ", 4)],
      (a, b, c, d) => show(a * c + b * d),
    ),
    fields(
      "Statistics",
      "Mean, median and sample standard deviation",
      [text("Values, separated by spaces or commas", "2, 4, 6")],
      (input) => {
        const terms = input.trim().split(/[\s,]+/);
        if (!input.trim() || terms.length > 1000)
          throw Error("Enter 1 to 1000 values.");
        const values = terms.map((v) =>
          /^[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?$/i.test(v) ? Number(v) : NaN,
        );
        if (!values.every(Number.isFinite))
          throw Error("Use finite numbers separated by spaces or commas.");
        values.sort((a, b) => a - b);
        const n = values.length,
          mid = Math.floor(n / 2),
          avg = values.reduce((a, b) => a + b, 0) / n;
        const sd =
          n > 1
            ? show(
                Math.sqrt(
                  values.reduce((sum, x) => sum + (x - avg) ** 2, 0) / (n - 1),
                ),
              )
            : "requires two values";
        return (
          "Mean " +
          show(avg) +
          " · median " +
          show(n % 2 ? values[mid] : (values[mid - 1] + values[mid]) / 2) +
          " · sample SD " +
          sd
        );
      },
    ),
    fields(
      "Circle",
      "A = πr²     C = 2πr",
      [num("Radius", 3)],
      (r) =>
        "Area " +
        show(Math.PI * nonnegative(r) ** 2) +
        " square units · circumference " +
        show(2 * Math.PI * r) +
        " units",
    ),
  );
  kits["Electrical Engineering"].push(
    fields(
      "Voltage divider",
      "Vout = Vin R₂ / (R₁ + R₂) · unloaded",
      [num("Input (V)", 12), num("R₁ (Ω)", 1000), num("R₂ (Ω)", 2000)],
      (v, a, b) =>
        show((v * nonnegative(b)) / positive(nonnegative(a) + b)) + " V",
    ),
    fields(
      "RC time",
      "τ = RC",
      [num("Resistance (kΩ)", 10), num("Capacitance (µF)", 10)],
      (r, c) => show(positive(r) * positive(c)) + " ms",
    ),
    fields(
      "Reactance",
      "Ideal AC elements · sinusoidal steady state",
      [
        num("Frequency (Hz)", 50),
        num("Inductance (mH)", 100),
        num("Capacitance (µF)", 100),
      ],
      (f, l, c) =>
        "Xᴸ " +
        show((2 * Math.PI * positive(f) * positive(l)) / 1000) +
        " Ω · |Xᶜ| " +
        show(1e6 / (2 * Math.PI * f * positive(c))) +
        " Ω",
    ),
    fields(
      "Capacitor energy",
      "E = ½CV²",
      [num("Capacitance (µF)", 1000), num("Voltage (V)", 10)],
      (c, v) => show((0.5 * positive(c) * v * v) / 1000) + " mJ",
    ),
  );
  kits["Mechanical Engineering"].push(
    fields(
      "Torque",
      "τ = rF sin θ",
      [num("Lever arm (m)", 0.5), num("Force (N)", 20), num("Angle (°)", 90)],
      (r, f, a) =>
        show(nonnegative(r) * nonnegative(f) * Math.sin((a * Math.PI) / 180)) +
        " N·m",
    ),
    fields(
      "Shaft power",
      "P = τω     ω = 2πn / 60",
      [num("Torque (N·m)", 20), num("Speed (rpm)", 1200)],
      (t, n) => show((t * 2 * Math.PI * n) / 60000) + " kW",
    ),
    fields(
      "Spring",
      "F = −kx     U = ½kx² · linear spring",
      [num("Stiffness (N/m)", 100), num("Extension (m)", 0.2)],
      (k, x) =>
        "Restoring force " +
        show(-positive(k) * x) +
        " N · energy " +
        show(0.5 * k * x * x) +
        " J",
    ),
    fields(
      "Expansion",
      "ΔL = α L₀ ΔT · constant coefficient",
      [
        num("Length (m)", 2),
        num("α (µm/m·K)", 12),
        num("Temperature change (K)", 50),
      ],
      (l, a, t) => show((positive(l) * a * t) / 1000) + " mm",
    ),
  );
  kits["Computer Science"].push(
    fields(
      "Bitwise",
      "Unsigned hexadecimal operands",
      [
        text("A (hex)", "F0"),
        choice("Operation", ["AND", "OR", "XOR"]),
        text("B (hex)", "3C"),
      ],
      (a, op, b) => {
        if (![a, b].every((s) => /^[0-9a-f]{1,32}$/i.test(s.trim())))
          throw Error("Use 1–32 hex digits per operand.");
        const x = BigInt("0x" + a.trim()),
          y = BigInt("0x" + b.trim());
        return (
          "0x" +
          (op === "AND" ? x & y : op === "OR" ? x | y : x ^ y)
            .toString(16)
            .toUpperCase()
        );
      },
    ),
    fields(
      "Data sizes",
      "1 kB = 1000 B     1 KiB = 1024 B",
      [num("Size", 1), choice("Unit", ["MiB", "MB", "KiB", "kB", "B", "bit"])],
      (n, u) => {
        const bytes =
          nonnegative(n) *
          { MiB: 1048576, MB: 1000000, KiB: 1024, kB: 1000, B: 1, bit: 0.125 }[
            u
          ];
        return show(bytes) + " B · " + show(bytes / 1048576) + " MiB";
      },
    ),
    fields(
      "Truth table",
      "Binary Boolean operations",
      [choice("Gate", ["AND", "OR", "XOR", "NAND", "NOR", "XNOR"])],
      (op) =>
        ["00", "01", "10", "11"]
          .map((pair) => {
            const a = Number(pair[0]),
              b = Number(pair[1]);
            return (
              pair[0] +
              " " +
              pair[1] +
              " → " +
              {
                AND: a & b,
                OR: a | b,
                XOR: a ^ b,
                NAND: 1 - (a & b),
                NOR: 1 - (a | b),
                XNOR: 1 - (a ^ b),
              }[op]
            );
          })
          .join("\n"),
    ),
    fields(
      "Binary search",
      "Worst-case probes in a sorted array",
      [num("Number of entries", 1024)],
      (n) => {
        if (!Number.isSafeInteger(n) || n < 0)
          throw Error("Enter a nonnegative safe integer.");
        return (n === 0 ? 0 : BigInt(n).toString(2).length) + " probes";
      },
    ),
  );
  global.GridnoteKits = { kits, molarMass, bases };
})(globalThis);
