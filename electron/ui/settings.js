/* Client-wide settings: color scheme and the unfocused-pane fade.

   Each host page is its own webmux:// origin, so localStorage would make
   these per host. Under the Electron client they live in main's config.json
   instead: the page GETs/PUTs them at /settings.json on its own origin (the
   bundle's protocol handler, never the tunnel), and main pushes a change to
   every other open host page as a 'webmux-settings' DOM event so all hosts
   flip together. Loaded any other way (dev forward straight to the server)
   the page falls back to localStorage. */

export const DEFAULTS = Object.freeze({ theme: 'dark', unfocusedFade: 40 });

// Theme ids double as the <html data-theme> value the stylesheets key on;
// only the terminal palette lives here because xterm paints on canvas.
export const THEMES = {
  dark: {
    label: 'Dark mode default',
    // xterm's stock palette on the panel color — the original look.
    xterm: { background: '#1f1f2b' },
  },
  light: {
    label: 'Light mode',
    xterm: {
      background: '#f4f5f9',
      foreground: '#343b58',
      cursor: '#343b58',
      cursorAccent: '#f4f5f9',
      selectionBackground: 'rgba(46, 125, 233, 0.25)',
      selectionInactiveBackground: 'rgba(46, 125, 233, 0.15)',
      black: '#3b3e4d',
      red: '#c8283f',
      green: '#587539',
      yellow: '#8c6c3e',
      blue: '#2e7de9',
      magenta: '#9854f1',
      cyan: '#007197',
      white: '#7d84a3',
      brightBlack: '#6a6f87',
      brightRed: '#f52a65',
      brightGreen: '#4d8a2f',
      brightYellow: '#a5772a',
      brightBlue: '#1c5fc4',
      brightMagenta: '#7c3de0',
      brightCyan: '#0a8fb5',
      brightWhite: '#343b58',
    },
  },
};

const CLIENT_STORE = location.protocol === 'webmux:'; // else localStorage
const LS_KEY = 'webmux-settings';

let settings = { ...DEFAULTS };
const listeners = new Set();

// Anything from storage or a push is untrusted-ish (an old config, a typo
// in config.json): unknown themes fall back to dark, the fade is clamped.
export function sanitize(raw) {
  const s = { ...DEFAULTS };
  if (raw && typeof raw === 'object') {
    if (typeof raw.theme === 'string' && THEMES[raw.theme]) s.theme = raw.theme;
    const fade = Number(raw.unfocusedFade);
    if (Number.isFinite(fade)) s.unfocusedFade = Math.round(Math.min(100, Math.max(0, fade)));
  }
  return s;
}

export const getSettings = () => settings;
export const themeOf = (s = settings) => THEMES[s.theme] || THEMES.dark;

// Called with the new settings after every apply; app.js repaints xterm
// themes from it. Returns an unsubscribe.
export function onSettingsChange(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

function apply(next) {
  settings = next;
  const root = document.documentElement;
  root.dataset.theme = settings.theme;
  // 0 = no fade at all; 40 reproduces the original brightness(0.72)/opacity
  // 0.85 look; 100 leaves unfocused panes clearly muted but still readable.
  root.style.setProperty('--unfocus-fade', String(settings.unfocusedFade / 100));
  for (const fn of listeners) fn(settings);
}

async function readStore() {
  if (CLIENT_STORE) {
    const res = await fetch('/settings.json', { cache: 'no-store' });
    if (!res.ok) throw new Error(`settings: ${res.status}`);
    return res.json();
  }
  return JSON.parse(localStorage.getItem(LS_KEY));
}

async function writeStore(s) {
  if (CLIENT_STORE) {
    const res = await fetch('/settings.json', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(s),
    });
    if (!res.ok) throw new Error(`settings: ${res.status}`);
    return;
  }
  localStorage.setItem(LS_KEY, JSON.stringify(s));
}

// Read the stored settings and apply them. Resolves even when the store is
// unreachable (defaults apply), so startup never hangs on it.
export async function loadSettings() {
  let raw = null;
  try { raw = await readStore(); } catch { /* defaults */ }
  apply(sanitize(raw));
  return settings;
}

// Apply a partial change immediately (live preview) and persist it. Under
// the client, persisting also fans the change out to the other host pages.
export async function updateSettings(patch, { persist = true } = {}) {
  apply(sanitize({ ...settings, ...patch }));
  if (persist) {
    try { await writeStore(settings); } catch (err) { console.warn('settings not saved:', err); }
  }
  return settings;
}

// A change made on another host's page (or a config.json edit) arrives via
// main as this event; apply it without writing it back.
window.addEventListener('webmux-settings', (ev) => apply(sanitize(ev.detail)));
