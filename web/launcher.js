(function (global) {
  function mount(host, options) {
    host.innerHTML = `<section class="start-card" aria-labelledby="start-title">
      <div class="identity"><img src="./assets/icon-192.png" width="35" height="35" alt=""><h1 id="start-title">Gridnote</h1></div>
      <button id="continue" hidden><span><b>Continue notebook</b><small></small></span>
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m8 5 7 7-7 7"/></svg></button>
      <div class="start-actions">
        <button id="new"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>New notebook</button>
        <button id="open"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 18V6a1 1 0 0 1 1-1h6l2 3h8v3M3 19l3-8h16l-3 8z"/></svg>Open file…</button>
      </div>
      <p id="detected-device" hidden></p><small id="offline-status" role="status"></small>
    </section>`;
    const find = (id) => host.querySelector("#" + id);
    const resume = find("continue");
    function recent(name, available) {
      resume.hidden = !available;
      resume.querySelector("small").textContent = name || "";
      find("new").classList.toggle("start-primary", !available);
    }
    recent(options.lastName, options.hasLast);
    for (const action of ["new", "open", "continue"])
      find(action).onclick = () => options.start(action);
    const device = find("detected-device");
    device.textContent = options.device || "";
    device.hidden = !device.textContent;
    return { recent };
  }
  global.GridnoteLauncher = { mount };
})(globalThis);
