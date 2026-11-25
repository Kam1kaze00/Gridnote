(() => {
  const catalog = {
    Default: {
      id: "refined",
      mark: "default-pencil.png",
      sprite: "tools",
      chrome: "#1a2027",
    },
    "70s Cartoon": {
      id: "seventies",
      mark: "pencil.png",
      sprite: "ink-tools",
      chrome: "#f5f1e6",
      tint: "Ivory",
    },
    "Tokyo Neon": {
      id: "tokyo",
      mark: "tokyo-pencil.png",
      sprite: "tokyo-tools",
      chrome: "#111e36",
      tint: "Pale Blue",
    },
    Cyberpunk: {
      id: "cyber",
      mark: "cyber-pencil.png",
      sprite: "cyber-tools",
      chrome: "#151a1c",
      tint: "Ivory",
    },
    Pixelated: {
      id: "pixel",
      mark: "pixel-pencil.svg",
      sprite: "pixel-tools",
      chrome: "#27382f",
      tint: "Sage",
    },
  };
  function apply(name) {
    const selected = Object.hasOwn(catalog, name)
      ? catalog[name]
      : catalog.Default;
    for (const style of Object.values(catalog))
      document.body.classList.toggle(style.id, style === selected);
    document.body.classList.toggle(
      "designed",
      ["tokyo", "cyber", "pixel"].includes(selected.id),
    );
    document.documentElement.style.colorScheme =
      selected.id === "seventies" ? "light" : "dark";
    return selected;
  }
  function fillPicker(picker) {
    for (const name of Object.keys(catalog)) picker.add(new Option(name, name));
  }
  globalThis.GridnoteAppearance = { catalog, apply, fillPicker };
})();
