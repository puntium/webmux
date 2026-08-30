// Bridge for the local pages (header.html, connect.html) only. Remote app
// pages get no bridge: profiles (and the ssh args stored in them), the list
// of other connections, and view switching must not be reachable from
// server-supplied content.
const { contextBridge, ipcRenderer } = require('electron');

if (location.protocol === 'file:') {
  contextBridge.exposeInMainWorld('webmux', {
    listProfiles: () => ipcRenderer.invoke('profiles:list'),
    saveProfile: (profile, originalName) => ipcRenderer.invoke('profiles:save', profile, originalName),
    deleteProfile: (name) => ipcRenderer.invoke('profiles:delete', name),
    connect: (name) => ipcRenderer.invoke('profiles:connect', name),
    getConns: () => ipcRenderer.invoke('conns:get'),
    onConns: (cb) => ipcRenderer.on('conns', (_ev, s) => cb(s)),
    showConn: (name) => ipcRenderer.invoke('conns:show', name), // null = connection page
    disconnect: (name) => ipcRenderer.invoke('conns:disconnect', name),
    reorderConns: (names) => ipcRenderer.invoke('conns:reorder', names), // pill drag order
    chromeCmd: (cmd) => ipcRenderer.invoke('conns:cmd', cmd), // header actions → active host page
    getSettings: () => ipcRenderer.invoke('settings:get'), // client-wide UI settings (theme)
    onSettings: (cb) => ipcRenderer.on('settings', (_ev, s) => cb(s)),
    // Connection log (logs.html tails it; connect.html opens the window).
    openLog: () => ipcRenderer.invoke('log:open'),
    getLog: (afterSeq) => ipcRenderer.invoke('log:get', afterSeq), // { entries, file }
    onLog: (cb) => ipcRenderer.on('log', (_ev, entry) => cb(entry)),
    clearLog: () => ipcRenderer.invoke('log:clear'),
    revealLog: () => ipcRenderer.invoke('log:reveal'), // show the file in Finder
  });
}
