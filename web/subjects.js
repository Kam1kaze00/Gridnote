const appearance = GridnoteAppearance.apply(
  new URLSearchParams(location.search).get("theme"),
);
document.documentElement.classList.toggle(
  "cartoon",
  appearance.id === "seventies",
);
const $ = (id) => document.getElementById(id);
const selectedMajor = decodeURIComponent(location.hash.slice(1)),
  tools = GridnoteKits.kits[selectedMajor] || [];
$("major").textContent = selectedMajor || "Study tools";
const send = window.webkit?.messageHandlers?.gridnoteInsert;
const insert = $("insert");
let result = "";
function display(value) {
  result = value;
  $("result").textContent = value;
  insert.hidden = !result || (!send && parent === window);
}
function failure(msg) {
  display("");
  $("result").textContent = msg;
}
insert.onclick = () => {
  const text = current.name + "\n" + result;
  if (send) send.postMessage(text);
  else
    parent.postMessage(
      { type: "gridnote-study-result", text },
      location.origin,
    );
};
function option(value) {
  const o = document.createElement("option");
  o.textContent = value;
  return o;
}
let current;
const elements = GridnoteElements;
function cellPosition(n) {
  if (n >= 57 && n <= 71) return [8, n - 54];
  if (n >= 89 && n <= 103) return [9, n - 86];
  const ends = [2, 10, 18, 36, 54, 86, 118];
  const row = ends.findIndex((v) => n <= v) + 1;
  if (row === 1) return [1, n === 1 ? 1 : 18];
  const offset = n - ends[row - 2];
  return [
    row,
    row <= 3 && offset > 2
      ? offset + 10
      : row >= 6 && offset > 17
        ? offset - 14
        : offset,
  ];
}
function chooseElement(e) {
  const [n, s, name, weight, family] = e;
  for (const b of $("grid").children)
    b.setAttribute("aria-pressed", String(b.dataset.symbol === s));
  display(
    name +
      " (" +
      s +
      ") · " +
      n +
      "\n" +
      family +
      "\n" +
      (weight === "—"
        ? "No standard atomic weight"
        : "Standard atomic weight   " + weight),
  );
}
function periodic() {
  const grid = $("grid");
  grid.replaceChildren();
  for (const e of elements) {
    const [n, s, name] = e,
      [row, col] = cellPosition(n);
    const b = document.createElement("button"),
      small = document.createElement("small");
    small.textContent = n;
    b.append(small, s);
    b.className = "element";
    const colors = {
      "Alkali metal": "#bb8391",
      "Alkaline earth metal": "#b3a168",
      "Transition metal": "#8e9ebc",
      Nonmetal: "#83b9a0",
      "Noble gas": "#a894ba",
      Halogen: "#83b2b5",
      Metalloid: "#b6af88",
      Lanthanide: "#b6a2c1",
      Actinide: "#c09a8e",
    };
    b.style.borderBottomColor = colors[e[4]] || "#929fa7";
    b.style.gridRow = row;
    b.style.gridColumn = col;
    b.dataset.symbol = s;
    b.setAttribute("aria-label", name + " (" + s + "), atomic number " + n);
    b.onclick = () => chooseElement(e);
    grid.append(b);
  }
  const search = $("search");
  search.value = "";
  search.oninput = () => {
    const q = search.value.trim().toLowerCase(),
      match =
        elements.find((e) => e[1].toLowerCase() === q || String(e[0]) === q) ||
        elements.find((e) => q && e[2].toLowerCase().startsWith(q));
    if (match) {
      chooseElement(match);
      grid
        .querySelector('[data-symbol="' + match[1] + '"]')
        .scrollIntoView({ block: "nearest", inline: "nearest" });
    } else if (q) failure("No matching element.");
    else chooseElement(elements[0]);
  };
  chooseElement(elements[0]);
}
function render() {
  current = tools[$("tool").selectedIndex];
  if (!current) return;
  $("fields").replaceChildren();
  $("formula").textContent = current.relation || "";
  $("periodic").hidden = !current.periodic;
  if (current.periodic) {
    periodic();
    return;
  }
  const controls = [];
  function update() {
    try {
      const values = controls.map((c, i) => {
        if (current.inputs[i].type !== "number") return c.value;
        if (!c.value.trim() || !Number.isFinite(c.valueAsNumber))
          throw Error("Enter each quantity.");
        return c.valueAsNumber;
      });
      display(current.calculate(...values));
    } catch (e) {
      failure(e.message);
    }
  }
  for (const f of current.inputs) {
    const l = document.createElement("label");
    l.textContent = f.label;
    const c = document.createElement(f.values ? "select" : "input");
    if (f.values) {
      for (const v of f.values) c.append(option(v));
    } else {
      c.type = f.type;
      c.step = "any";
    }
    c.value = f.value;
    c.oninput = update;
    controls.push(c);
    l.append(c);
    $("fields").append(l);
  }
  update();
}
for (const t of tools) $("tool").append(option(t.name));
const requestedTool = new URLSearchParams(location.search).get("tool");
if (tools.some((t) => t.name === requestedTool))
  $("tool").value = requestedTool;
$("tool").onchange = render;
render();