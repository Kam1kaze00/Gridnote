(function (global) {
  function mount(host, options) {
    host.innerHTML = `<section class="start-card" aria-labelledby="start-title">
      <div class="start-cover" role="img"></div>
      <div class="start-content"><h1 id="start-title">Open your notebook</h1>
        <div class="start-fields"><label class="start-label" for="welcome-major">Major<select id="welcome-major" aria-label="Major"></select></label>
          <label class="start-label" for="welcome-theme">Theme<select id="welcome-theme" aria-label="Theme"><option>Default</option><option>70s Cartoon</option></select></label></div>
        <div class="start-preview" aria-live="polite"></div>
        <p id="detected-device" class="start-meta" hidden></p>
        <div class="start-actions"><button id="continue" class="start-continue" hidden><span>Continue notebook</span><small></small></button>
          <button id="new">New notebook</button><button id="open">Open file…</button></div>
        <div id="recents"></div><small id="offline-status" role="status"></small>
      </div></section>`;
    const find = (id) => host.querySelector("#" + id);
    const select = find("welcome-major"),
      preview = host.querySelector(".start-preview");
    const catalog = global.GridnoteKits.kits;
    for (const name of ["None", ...Object.keys(catalog)])
      select.add(new Option(name, name));
    function selectMajor(value) {
      select.value = Object.hasOwn(catalog, value) ? value : "None";
      preview.replaceChildren();
      if (select.value === "None") {
        preview.textContent = "Standard writing tools";
      } else {
        for (const tool of catalog[select.value]) {
          const chip = document.createElement("span");
          chip.textContent = tool.name;
          preview.append(chip);
        }
      }
    }
    const themePicker = find("welcome-theme");
    function selectTheme(value) {
      const cartoon = value === "70s Cartoon";
      themePicker.value = cartoon ? "70s Cartoon" : "Default";
      document.body.classList.toggle("seventies", cartoon);
      document.body.classList.toggle("refined", !cartoon);
      host
        .querySelector(".start-cover")
        .setAttribute(
          "aria-label",
          cartoon
            ? "Gridnote with a cartoon pencil and graph-paper notebook"
            : "Gridnote on engineering paper beside a pen",
        );
    }
    selectTheme(options.theme);
    themePicker.onchange = () => {
      selectTheme(themePicker.value);
      options.changeTheme(themePicker.value);
    };
    function recent(name, available) {
      find("continue").hidden = !available;
      find("continue").querySelector("small").textContent = name || "";
      find("new").classList.toggle("start-primary", !available);
    }
    selectMajor(options.major);
    recent(options.lastName, options.hasLast);
    select.onchange = () => {
      selectMajor(select.value);
      options.change(select.value);
    };
    find("new").onclick = () => options.start("new");
    find("open").onclick = () => options.start("open");
    find("continue").onclick = () => options.start("continue");
    const device = find("detected-device");
    device.textContent = options.device || "";
    device.hidden = !device.textContent;
    return { selectMajor, selectTheme, recent };
  }
  global.GridnoteLauncher = { mount };
})(globalThis);
