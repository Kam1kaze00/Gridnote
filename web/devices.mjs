export const devices = {
  wacom: ["Wacom · two-button pen", true, 2],
  wacomSingle: ["Wacom · one-button pen", true, 1],
  huion: ["Huion · Inspiroy / Kamvas", true, 2],
  xppen: ["XPPen · Deco / Artist", true, 2],
  xencelabs: ["Xencelabs · Pen Tablet / Display", true, 2],
  apple: ["iPad · Apple Pencil", true, 0],
  appleUSB: ["iPad · Apple Pencil (USB-C)", false, 0],
  surface: ["Surface Pen / Slim Pen", true, 1],
  spen: ["Samsung S Pen", true, 1],
  usi: ["Chromebook · USI stylus", true, 0],
  other: ["Other active pen", true, 2],
  touch: ["Finger / passive stylus", false, 0],
  mouse: ["Mouse / trackpad", false, 2],
};
const agent = navigator.userAgent;
export const mobileSurface =
  (navigator.maxTouchPoints > 0 && matchMedia("(pointer:coarse)").matches) ||
  navigator.maxTouchPoints > 1 ||
  /Android|iPad|iPhone/.test(agent);
const appleSurface =
  /iPad/.test(agent) ||
  (/Mac/.test(navigator.platform) &&
    navigator.maxTouchPoints > 1 &&
    !/Android|iPhone/.test(agent));
const initial = appleSurface ? "apple" : mobileSurface ? "touch" : "mouse";
let prefs;
try {
  prefs = JSON.parse(localStorage.getItem("gridnote-pens") || "{}");
} catch {
  prefs = {};
}
export let device = initial;
let hardware = null,
  observedPen = false;
export const majors = [
  "None",
  "Chemistry",
  "Physics",
  "Medicine",
  "Mathematics",
  "Electrical Engineering",
  "Computer Science",
  "Mechanical Engineering",
];
export const major = () =>
  majors.includes(prefs.major) ? prefs.major : "None";
export function chooseMajor(v) {
  if (majors.includes(v)) {
    prefs.major = v;
    remember();
  }
}
export const themes = Object.keys(GridnoteAppearance.catalog);
export function theme() {
  return themes.includes(prefs.theme) ? prefs.theme : themes[0];
}
export function chooseTheme(value) {
  if (themes.includes(value)) { prefs.theme = value; remember(); }
}
export function deviceLabel() {
  if (hardware) return hardware.name + " · Detected";
  if (observedPen)
    return (appleSurface ? "iPad stylus" : "Active pen") + " · Detected";
  return mobileSurface ? "Touch and pen" : "Ready for pen or mouse";
}
export async function detectHardware() {
  if (mobileSurface) return;
  let found = null,
    list = [];
  try {
    list = (await navigator.hid?.getDevices()) || [];
  } catch {}
  for (const hid of list) {
    const profiles = { 1386: "wacom", 9580: "huion", 10429: "xppen" };
    const profile = profiles[hid.vendorId];
    if (profile && hid.productName) {
      found = { profile, name: hid.productName };
      break;
    }
  }
  if (
    !found &&
    location.hostname === "127.0.0.1" &&
    location.port === "48765"
  ) {
    try {
      const res = await fetch("./_gridnote-device");
      if (res.headers.get("content-type")?.includes("application/json")) {
        const d = await res.json();
        if (devices[d.profile] && d.name) found = d;
      }
    } catch {}
  }
  hardware = found;
  device = hardware?.profile || (observedPen ? "other" : initial);
}
export function observePointer(e) {
  if (e.pointerType === "pen") {
    const profile = hardware?.profile || (appleSurface ? "apple" : "other");
    if (!observedPen && prefs.pendingTuning) {
      prefs[profile] = { ...prefs[profile], ...prefs.pendingTuning };
      delete prefs.pendingTuning;
      remember();
    }
    observedPen = true;
    device = profile;
  } else if (
    e.pointerType === "mouse" &&
    !mobileSurface &&
    !hardware &&
    !observedPen
  ) {
    device = "mouse";
  } else if (e.pointerType === "touch" && !observedPen && !appleSurface) {
    device = "touch";
  }
}
export function fingerWrites() {
  return prefs.fingerWriting ?? device === "touch";
}
export function useFinger(value) {
  prefs.fingerWriting = value;
  remember();
}
const tipWidths = { Pen: 1.5, Brush: 2, Fineliner: 0.9 };
const deviceTuning = new Set(["pressure", "smoothing", "scroll"]);
export const defaultSettings = {
  nib: "Brush",
  usePressure: true,
  width: 2,
  smoothing: 0.48,
  pressure: 1,
  scroll: 0.3,
  diameter: 18,
  ink: 0,
  textInk: 0,
  textSize: 14,
  textTraits: 0,
  tableText: null,
  alignment: "Auto",
  select: "Tap",
  erase: "Stroke",
  mask: 7,
  palette: true,
  guides: true,
  shapeWidth: 2,
  markerWidth: 11,
  opacity: 0.38,
  markerInk: 0,
  shape: "Line",
  constrain: false,
  code: false,
  rows: 3,
  columns: 3,
  header: true,
  tableWidth: 240,
  tableHeight: 84,
};
export function pressureResponse(p, force) {
  if (!p.usePressure || p.nib === "Fineliner" || !Number.isFinite(force)) return 1;
  const level = Math.pow(Math.max(0, Math.min(1, force)), p.pressure);
  return p.nib === "Pen"
    ? 0.74 + 0.36 * (1 - Math.pow(1 - level, 1.4))
    : 0.12 + 2.48 * level * level * (3 - 2 * level);
}
export function sampledRadius(p, force, previous, distance, elapsed, lift, stylus) {
  if (!p.usePressure || p.nib === "Fineliner") return p.width / 2;
  if (lift && previous != null) {
    if (p.nib !== "Brush" || distance < 0.12) return previous;
    return Math.max(p.width * pressureResponse(p, 0) / 2,
      previous * Math.exp(-distance / Math.max(1, p.width)));
  }
  const dt = Math.max(0.001, elapsed);
  if (force == null && p.nib === "Brush" && !stylus)
    force = previous == null ? 0.42 : 0.22 + 0.54 / (1 + distance / (dt * 230));
  if (force == null) return previous ?? p.width / 2;
  const target = p.width * pressureResponse(p, force) / 2;
  if (previous == null) return target;
  const response = p.nib === "Brush" && target > previous ? 0.011 : 0.0035;
  return target + (previous - target) * Math.exp(-dt / response);
}
export function restore(tool) {
  if (!tool) prefs = {};
  else {
    const keys = {
      brush: ["nib", "usePressure", "width", "smoothing", "pressure", "ink"],
      selector: ["select", "guides", "mask"],
      eraser: ["erase", "diameter"],
      text: ["textSize", "textInk", "alignment", "textTraits", "code"],
      marker: ["markerWidth", "opacity", "markerInk"],
      shapes: ["shape", "shapeWidth", "constrain"],
      table: ["rows", "columns", "header", "tableWidth", "tableHeight", "tableText"],
    };
    for (const key of keys[tool]) {
      if (prefs.tools) delete prefs.tools[key];
      if (prefs.pendingTuning) delete prefs.pendingTuning[key];
      const profiles = deviceTuning.has(key) ? [device] : Object.keys(devices);
      for (const profile of profiles) if (prefs[profile]) delete prefs[profile][key];
    }
    if (tool === "brush") delete prefs.tipWidths;
  }
  remember();
}
export function settings() {
  const legacy = prefs[device] || {};
  const nib = prefs.tools?.nib || legacy.nib || "Brush";
  const previousWidth = nib === (legacy.nib || "Brush") ? legacy.width : undefined;
  return {
    ...defaultSettings,
    smoothing: ["mouse", "touch"].includes(device) ? 0.65 : 0.48,
    ...legacy,
    ...prefs.tools,
    nib,
    width: prefs.tipWidths?.[nib] ?? previousWidth ?? tipWidths[nib] ?? tipWidths.Brush,
  };
}
function remember() {
  try {
    localStorage.setItem("gridnote-pens", JSON.stringify(prefs));
  } catch {
    /* Notebook persistence is handled separately by IndexedDB. */
  }
}
export function setting(key, value) {
  if (key === "width") {
    prefs.tipWidths = { ...prefs.tipWidths, [settings().nib]: value };
  } else if (deviceTuning.has(key)) {
    prefs[device] = { ...prefs[device], [key]: value };
    // Preserve adjustments made before the first pen event identifies the tablet.
    if (!hardware && !observedPen) prefs.pendingTuning = { ...prefs.pendingTuning, [key]: value };
  } else {
    prefs.tools = { ...prefs.tools, [key]: value };
  }
  remember();
}
export function deviceHelp() {
  if (device === "touch")
    return "Draw with one finger. Use two fingers to pan or pinch to zoom.";
  if (device === "mouse")
    return "Drag to write. Scroll with the wheel or trackpad. Space-drag pans vertically.";
  if (devices[device][2] === 2)
    return "In the tablet driver, map the upper switch to Right Click and the lower switch to Middle Click. The upper switch erases until tip lift. Hold the lower switch to scroll.";
  if (devices[device][2] === 1)
    return "A side switch reported as Right Click erases until tip lift. Scroll with a finger, trackpad, or Space-drag.";
  return "Write with the pen. Scroll with a finger and pinch to zoom. Use the toolbar for erasing.";
}
