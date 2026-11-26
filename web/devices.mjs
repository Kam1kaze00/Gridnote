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
if (!prefs || typeof prefs !== "object" || Array.isArray(prefs)) prefs = {};
if (Object.hasOwn(prefs, "major") || Object.hasOwn(prefs, "theme")) {
  delete prefs.major;
  delete prefs.theme;
  remember();
}
export let device = initial;
let hardware = null,
  observedPen = false;
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
const tipWidths = { Pen: 1.5, Brush: 2, Fineliner: 0.9, Gel: 2.5, Fountain: 4.2, Pencil: 2.1 };
const deviceTuning = new Set(["pressure", "smoothing", "scroll"]);
export const defaultSettings = {
  nib: "Brush",
  brushFinish: "Inked",
  usePressure: true,
  penFlow: 1,
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
  if (p.nib === "Gel") return 0.94 + 0.12 * level;
  if (p.nib === "Fountain") return 0.75 + 0.48 * level;
  if (p.nib === "Pencil") return 0.32 + 1.35 * level;
  return p.nib === "Pen"
    ? 0.74 + 0.36 * level * (0.72 + 0.28 * level)
    : 0.085 + (p.brushFinish === "Dry" ? 3.04 * level ** 1.06 : 2.88 * level ** 1.16);
}
export function brushMotion(previous, distance, elapsed, width) {
  const velocity = Math.min(1200, distance / Math.max(0.001, elapsed));
  return {
    travel: (previous?.travel ?? 0) + distance / width,
    speed: previous?.travel > 0 ? (previous.speed ?? velocity)*0.72 + velocity*0.28 : velocity,
  };
}
export function sampledRadius(p, force, previous, distance, elapsed, lift, stylus, crossTilt = 0) {
  if (!p.usePressure || p.nib === "Fineliner") return p.width / 2;
  if (lift && previous != null) {
    if (p.nib !== "Brush" || distance < 0.12) return previous;
    return Math.max(p.width * pressureResponse(p, 0) / 2,
      previous * Math.exp(-distance / Math.max(1, p.width)));
  }
  const dt = Math.max(0.001, elapsed);
  if (force == null && p.nib !== "Pen" && !stylus)
    force = previous == null ? 0.42 : 0.22 + 0.54 / (1 + distance / (dt * 230));
  if (p.nib === "Pen") {
    const load = force ?? (stylus ? null : 0.62);
    if (load != null) {
      const dwell = previous == null ? 0 : 0.13 * (1 / (1 + distance / (dt * 180)) - 0.40);
      force = Math.max(0, Math.min(1, load + dwell));
    }
  }
  if (force == null) return previous ?? p.width / 2;
  const tiltGain = p.nib === "Brush" ? 0.65 : p.nib === "Pencil" ? 1.5 : 0;
  const spread = 1 + tiltGain * Math.min(1, Math.abs(crossTilt)) * force;
  const target = p.width * pressureResponse(p, force) * spread / 2;
  if (previous == null) return target;
  const response = p.nib === "Brush" ? (target > previous ? 0.014 : 0.007) : 0.0035;
  return target + (previous - target) * Math.exp(-dt / response);
}
export function restore(tool) {
  if (!tool) prefs = {};
  else {
    const keys = {
      brush: ["nib", "brushFinish", "usePressure", "penFlow", "width", "smoothing", "pressure", "ink"],
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
