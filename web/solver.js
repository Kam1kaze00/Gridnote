// The native and portable clients use this same bounded expression parser.
// Polynomial coefficients are stored in ascending powers of the unknown.
(function (global) {
  "use strict";
  const fmt = (n) => Number(n.toPrecision(10)).toString();
  const scalar = (p) => p[1] === 0 && p[2] === 0;
  const constant = (n) => [n, 0, 0];
  function product(a, b) {
    if (a[2] * b[2] !== 0 || a[1] * b[2] + a[2] * b[1] !== 0)
      throw Error("Degree above two.");
    return [
      a[0] * b[0],
      a[0] * b[1] + a[1] * b[0],
      a[0] * b[2] + a[1] * b[1] + a[2] * b[0],
    ];
  }
  function normalized(s) {
    return s
      .replace(/[−–]/g, "-")
      .replace(/[×·⋅∙]/g, "*")
      .replace(/(\d)\s+\.\s+(?=\d)/g, "$1*")
      .replace(/(\d)\s*[xX]\s*(?=\d)/g, "$1*")
      .replace(/÷/g, "/")
      .replace(/²/g, "^2")
      .replace(/³/g, "^3");
  }
  function expression(source, state, steps) {
    const clean = normalized(source).trim();
    if (!clean || clean.length > 480) throw Error("Unsupported length.");
    const tokens = clean.match(
      /(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|[a-zA-Z]+|[()+*/^\-]|\S/g,
    );
    if (!tokens || tokens.length > 160) throw Error("Expression too long.");
    let i = 0;
    function atom() {
      const t = tokens[i++];
      if (t === "(") {
        const a = sum();
        if (tokens[i++] !== ")") throw Error("Missing parenthesis.");
        return a;
      }
      if (/^(?:\d|\.)/.test(t ?? "")) return constant(Number(t));
      if (/^[A-Za-z]$/.test(t ?? "")) {
        if (state.variable && t !== state.variable)
          throw Error("More than one unknown.");
        state.variable = t;
        return [0, 1, 0];
      }
      throw Error("Unknown term.");
    }
    function power() {
      let a = atom();
      if (tokens[i] === "^") {
        i++;
        const exp = unary();
        if (!scalar(exp)) throw Error("Variable exponent.");
        if (scalar(a)) {
          const ans = a[0] ** exp[0];
          steps.push(fmt(a[0]) + " ^ " + fmt(exp[0]) + " = " + fmt(ans));
          return constant(ans);
        }
        if (![0, 1, 2].includes(exp[0])) throw Error("Unsupported exponent.");
        if (exp[0] === 0) a = constant(1);
        if (exp[0] === 2) a = product(a, a);
      }
      return a;
    }
    function unary() {
      if (tokens[i] === "-" || tokens[i] === "+") {
        const neg = tokens[i++] === "-";
        const a = unary();
        return neg ? a.map((v) => -v) : a;
      }
      return power();
    }
    function combine(a, b, op) {
      let c;
      if (op === "*") c = product(a, b);
      else if (op === "/") {
        if (!scalar(b) || b[0] === 0) throw Error("Undefined division.");
        c = a.map((v) => v / b[0]);
      } else c = a.map((v, j) => v + (op === "+" ? 1 : -1) * b[j]);
      if (!c.every(Number.isFinite)) throw Error("Non-finite result.");
      if (scalar(a) && scalar(b) && steps.length < 12)
        steps.push(
          fmt(a[0]) +
            " " +
            ({ "*": "×", "/": "÷" }[op] || op) +
            " " +
            fmt(b[0]) +
            " = " +
            fmt(c[0]),
        );
      return c;
    }
    function term() {
      let a = unary();
      while (i < tokens.length) {
        const t = tokens[i],
          implicit = t === "(" || /^[a-zA-Z]$/.test(t);
        if (!implicit && t !== "*" && t !== "/") break;
        if (!implicit) i++;
        a = combine(a, unary(), implicit ? "*" : t);
      }
      return a;
    }
    function sum() {
      let a = term();
      while (tokens[i] === "+" || tokens[i] === "-") {
        const op = tokens[i++];
        a = combine(a, term(), op);
      }
      return a;
    }
    const result = sum();
    if (i !== tokens.length || !result.every(Number.isFinite))
      throw Error("Unrecognized expression.");
    return result;
  }
  function math(raw) {
    const source = normalized(raw.trim())
      .replace(
        /^(?:please\s+)?(?:solve(?:\s+for\s+[A-Za-z])?|calculate|evaluate|what is|find the value of)\s*[:\s]\s*/i,
        "",
      )
      .replace(/\s*=\s*\??$/, "")
      .replace(/\s*[?.]\s*$/, "");
    const sides = source.split("=");
    if (sides.length > 2 || !/[0-9]/.test(source) || !/[=+*/^()-]/.test(source))
      return null;
    const steps = [],
      state = {};
    try {
      const l = expression(sides[0], state, steps);
      if (sides.length === 1) {
        if (!scalar(l) || !steps.length) return null;
        return { steps, answer: fmt(l[0]) };
      }
      const r = expression(sides[1], state, steps),
        [c, b, a] = l.map((v, i) =>
          Math.abs(v - r[i]) <=
          Number.EPSILON * 4 * Math.max(Math.abs(v), Math.abs(r[i]))
            ? 0
            : v - r[i],
        ),
        x = state.variable || "x";
      if (!Number.isFinite(a + b + c)) return null;
      if (!a && !b)
        return {
          steps: [
            ...steps,
            "Subtract the right side from both sides: " + fmt(c) + " = 0.",
          ],
          answer: state.variable
            ? c === 0
              ? "All real values of " + x
              : "No solution"
            : c === 0
              ? "True"
              : "False",
        };
      if (!a && !Number.isFinite(-c / b)) return null;
      if (!a)
        return {
          steps: [
            ...steps,
            "Collect like terms: " + fmt(b) + x + " + (" + fmt(c) + ") = 0.",
            "Subtract " +
              fmt(c) +
              " from both sides: " +
              fmt(b) +
              x +
              " = " +
              fmt(-c) +
              ".",
            "Divide both sides by " + fmt(b) + ".",
          ],
          answer: x + " = " + fmt(-c / b),
        };
      const d = b * b - 4 * a * c;
      if (!Number.isFinite(d)) return null;
      const work = [
        ...steps,
        "Collect terms in a" + x + "² + b" + x + " + c = 0.",
        "a = " + fmt(a) + ", b = " + fmt(b) + ", c = " + fmt(c) + ".",
        "Discriminant b² − 4ac = " + fmt(d) + ".",
        "Use " + x + " = (−b ± √D) / (2a).",
      ];
      if (d < 0) return { steps: work, answer: "No real roots" };
      const q = -0.5 * (b + (b >= 0 ? 1 : -1) * Math.sqrt(d)),
        roots = d === 0 ? [-b / (2 * a)] : [q / a, c / q].sort((u, v) => u - v);
      if (!roots.every(Number.isFinite)) return null;
      return { steps: work, answer: x + " = " + roots.map(fmt).join(" or ") };
    } catch {
      return null;
    }
  }
  const codeLike = (s) =>
    /(?:^\s*(?:def|class|function|func|return|let|var|const|int|float|SELECT|fn|public|print|console\.log|printf|System\.out|cout|import|#include)\b|[;{}]\s*$|=>|:=)/im.test(
      s,
    );
  const question = (s) =>
    /\?\s*$/.test(s) ||
    /^(?:find|calculate|determine|explain|solve|what|why|how|given|compute|evaluate)\b/i.test(
      s.trim(),
    );
  function convertUnits(text) {
    const input = text.trim().replace(/[μµ]/g, "u").replace(/ohms?/gi, "Ω");
    const match = input.match(
      /^(?:[Cc]onvert\s+)?([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?)\s*([\wΩ/]+)\s*(?:\bto\b|\bin\b|→|->)\s*([\wΩ/]+)[?.]?$/,
    );
    if (!match) return null;
    function unit(s) {
      const fixed = {
        "km/h": ["speed", 1 / 3.6],
        "m/s": ["speed", 1],
        "cm/s": ["speed", 0.01],
        min: ["s", 60],
        h: ["s", 3600],
      };
      if (Object.hasOwn(fixed, s)) return fixed[s];
      const m = s.match(/^([pnumcdkMG]?)(Hz|Pa|mol|Ω|V|A|W|J|N|F|H|s|m|g|L)$/);
      if (!m) return null;
      const factors = {
        p: 1e-12,
        n: 1e-9,
        u: 1e-6,
        m: 1e-3,
        c: 0.01,
        d: 0.1,
        "": 1,
        k: 1e3,
        M: 1e6,
        G: 1e9,
      };
      return [m[2], factors[m[1]]];
    }
    const [, amount, src, dst] = match,
      from = unit(src),
      to = unit(dst);
    if (!from || !to || from[0] !== to[0]) return null;
    const ratio = from[1] / to[1],
      result = Number(amount) * ratio;
    if (!Number.isFinite(result)) return null;
    const name = (s) => s.replace(/^u/, "µ"),
      answer = fmt(result) + " " + name(dst);
    return {
      kind: "Equation",
      steps: [
        "1 " + name(src) + " = " + fmt(ratio) + " " + name(dst) + ".",
        "Multiply " + amount + " by the conversion factor.",
      ],
      answer,
    };
  }
  function solve(text, code = false) {
    if (typeof text !== "string" || !text.trim() || text.length > 16000)
      return null;
    if (!code) {
      const conversion = convertUnits(text);
      if (conversion) return conversion;
      const m = math(text);
      if (m) return { kind: "Equation", ...m };
    }
    if (code || codeLike(text)) {
      // Only return local output for a single, literal integer expression whose
      // operators have the same meanings across the supported print syntaxes.
      const statement = text
        .trim()
        .match(
          /^(?:print|console\.log|System\.out\.println|puts)\s*\(\s*([0-9\s()+*\-]+)\s*\)\s*;?$/,
        );
      if (statement) {
        const m = math(statement[1]);
        if (
          m &&
          Number.isSafeInteger(Number(m.answer)) &&
          /^[\d\s()+*\-]{1,64}$/.test(statement[1]) &&
          !statement[1].match(/\d{7,}/)
        )
          return {
            kind: "Code",
            steps: [...m.steps, "Print the resulting value."],
            answer: m.answer,
          };
      }
      const ret = text
        .trim()
        .match(
          /^return\s+([A-Za-z_]\w*)\s*([+*\-])\s*([A-Za-z_]\w*|\d+(?:\.\d+)?)\s*;?$/,
        );
      if (ret) {
        const [, a, op, b] = ret;
        const operation =
          op === "*" && a === b
            ? "Square " + a
            : { "*": "Multiply ", "+": "Add ", "-": "Subtract from " }[op] +
              a +
              (op === "*" ? " by " : op === "+" ? " and " : " the value ") +
              b;
        const names = [
          ...new Set([a, b].filter((v) => /^[A-Za-z_]/.test(v))),
        ].join(", ");
        return {
          kind: "Code",
          steps: [
            "Read the operand values: " + names + ".",
            operation + ".",
            "Return the expression to the caller.",
          ],
          answer:
            "For numeric operands, the returned value is " +
            a +
            " " +
            op +
            " " +
            b +
            ". A numeric result needs " +
            names +
            ".",
        };
      }
      const declaration = text
        .trim()
        .match(
          /^(?:(?:const|let|var|int|double|float|long|final)\s+)?([A-Za-z_]\w*)\s*(?::=|=)\s*(-?\d{1,6}(?:\s*[+*\-]\s*\d{1,6})?)\s*;?$/,
        );
      if (declaration) {
        const [, name, rhs] = declaration,
          m = math(rhs),
          value = m?.answer ?? rhs.trim();
        if (
          Number.isSafeInteger(Number(value)) &&
          Math.abs(Number(value)) <= 32767
        )
          return {
            kind: "Code",
            steps: [
              ...(m?.steps || []),
              "Assign the resulting integer to " + name + ".",
            ],
            answer: name + " = " + value,
          };
      }
      return { kind: "Code", steps: [], answer: null };
    }
    return question(text)
      ? { kind: "Question", steps: [], answer: null }
      : null;
  }
  function prompt(text, kind) {
    return (
      (kind === "Code"
        ? "Explain this code fragment as a tutor. Infer the language only when supported. Treat it as a fragment; no main function is required. Trace the relevant steps and give the output if it follows from the snippet. State any missing inputs or assumptions."
        : "Solve the following exercise as a tutor. Show concise steps and the final answer with units. State any missing information.") +
      "\n\n" +
      text
    );
  }
  // OCR confuses crossed handwritten letters with operators. Only propose a
  // variable at a coefficient boundary in an equation, and require review.
  function readInk(raw, alternatives = []) {
    if (typeof raw !== "string" || raw.length > 480 || !raw.includes("="))
      return raw;
    const suggested = raw.replace(/(\d)\s*[×*](?=\s*(?:[+=^)]|$))/g, "$1x");
    if (suggested !== raw && math(suggested)) return suggested;
    if (math(raw)) return raw;
    for (const candidate of alternatives) {
      if (
        typeof candidate === "string" &&
        candidate.replace(/[xXyY×*⋅·∙\s]/g, "") ===
          raw.replace(/[xXyY×*⋅·∙\s]/g, "") &&
        math(candidate)
      )
        return candidate;
    }
    return raw;
  }
  global.GridnoteSolve = { solve, prompt, readInk };
})(globalThis);
