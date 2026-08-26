/* Where this page's webmux server lives.

   Under the Electron client the page is served from the app bundle on the
   webmux:// scheme (main.js protocol handler) and the server API rides the
   SSH tunnel at http://127.0.0.1:<port> — the port arrives as a query
   parameter on the page URL. Loaded any other way (e.g. a dev forward
   straight to the server's unix socket), fall back to the page's own origin
   so relative-style fetches keep working. */

const port = new URLSearchParams(location.search).get('port');

// Prefix for fetch()/img URLs: `${API}/api/...`. Empty string = same origin.
export const API = port ? `http://127.0.0.1:${port}` : '';

// Prefix for WebSocket URLs: `${WS_BASE}/ws?...`.
export const WS_BASE = port
  ? `ws://127.0.0.1:${port}`
  : `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}`;
