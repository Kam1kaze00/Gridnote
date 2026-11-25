const designs = [
  [
    "Default",
    "default",
    "A waving pencil on a teal drafting desk. Open the notebook to write on the familiar blue grid.",
  ],
  [
    "70s Cartoon",
    "cartoon",
    "A pencil with a grin. Cream stock, inked tools, and a double-rule margin.",
  ],
  [
    "Tokyo Neon",
    "tokyo",
    "Follow the turquoise line. Route-sign lettering and station-number folios on blue paper.",
  ],
  [
    "Cyberpunk",
    "cyber",
    "An amber instrument panel, monospaced readouts, and a fine drafting grid.",
  ],
  [
    "Pixelated",
    "pixel",
    "Pocket-size pixels, full-size working paper. Four green tones and a pencil built one square at a time.",
  ],
];
const get = (id) => document.getElementById(id);
let view = "editor";
function show(id) {
  const [name, key, description] =
    designs.find((d) => d[1] === id) || designs[0];
  const style = GridnoteAppearance.apply(name);
  get("logo").src = "../assets/" + style.mark;
  get("title").textContent = name;
  get("description").textContent = description;
  get("screen").src = "../images/" + key + "-" + view + ".png";
  get("screen").alt =
    name +
    " " +
    (view === "editor"
      ? "notebook showing a worked circuit exercise"
      : "startup launcher");
  document.body.dataset.view = view;
  for (const el of get("choices").children)
    el.setAttribute("aria-pressed", String(el.dataset.theme === key));
  for (const el of document.querySelectorAll("[data-view] button[data-view]"))
    el.setAttribute("aria-pressed", String(el.dataset.view === view));
}
for (const [name, id] of designs) {
  const b = document.createElement("button");
  b.textContent = name;
  b.dataset.theme = id;
  b.onclick = () => {
    location.hash = id;
    show(id);
  };
  get("choices").append(b);
}
for (const b of document.querySelectorAll("button[data-view]"))
  b.onclick = () => {
    view = b.dataset.view;
    show(location.hash.slice(1));
  };
window.addEventListener("hashchange", () => show(location.hash.slice(1)));
show(location.hash.slice(1));
