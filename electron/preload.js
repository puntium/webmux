// Bridge for the local connection page only. The remote app page gets no
// bridge: profile management (and the ssh args stored in profiles) must not
// be reachable from server-supplied content.
const { contextBridge, ipcRenderer } = require('electron');

if (location.protocol === 'file:') {
  contextBridge.exposeInMainWorld('webmux', {
    listProfiles: () => ipcRenderer.invoke('profiles:list'),
    saveProfile: (profile, originalName) => ipcRenderer.invoke('profiles:save', profile, originalName),
    deleteProfile: (name) => ipcRenderer.invoke('profiles:delete', name),
    connect: (name) => ipcRenderer.invoke('profiles:connect', name),
    getStatus: () => ipcRenderer.invoke('status:get'),
    onStatus: (cb) => ipcRenderer.on('status', (_ev, s) => cb(s)),
  });
}
