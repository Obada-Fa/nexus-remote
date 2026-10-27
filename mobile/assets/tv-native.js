// Only app-specific controls. The complete remote UI is served by the TV itself.
// Use its existing row/switch classes; no second theme or remote implementation.
(() => {
  if (!window.NexusTv || window.NexusNative) return;
  const access = document.getElementById('phone-access');
  if (!access) return;
  const make = (tag, cls, text) => {
    const node = document.createElement(tag); node.className = cls || '';
    if (text) node.textContent = text;
    return node;
  };
  const send = action => window.NexusTv.postMessage(JSON.stringify({action}));
  let native = {supported: false, enabled: false, busy: false};
  let media = null;
  // Use the existing phone-media button for the Android session as well. A
  // WebView silent-audio session would compete with the remote volume provider.
  if (typeof TVMediaControls === 'function') {
    const original = {toggle: TVMediaControls.prototype.toggle,
      update: TVMediaControls.prototype.update, paint: TVMediaControls.prototype.paint,
      disconnect: TVMediaControls.prototype.disconnect};
    TVMediaControls.prototype.toggle = function () {
      if (!native.supported) return original.toggle.call(this);
      send(native.enabled ? 'stop' : 'start');
    };
    TVMediaControls.prototype.update = function (state) {
      if (!native.supported) return original.update.call(this, state);
      if (this.started) { this.enabled = false; this.release(); }
      media = this;
      this.track = state?.gui === false ? null : this.current(state);
      this.paint();
    };
    TVMediaControls.prototype.paint = function () {
      if (!native.supported) return original.paint.call(this);
      this.button.hidden = !this.track;
      this.button.disabled = !!native.busy;
      this.button.setAttribute('aria-pressed', String(!!native.enabled));
      this.button.textContent = native.enabled ? 'Phone media controls on · Turn off' : 'Show in phone media controls';
    };
    TVMediaControls.prototype.disconnect = function () {
      if (!native.supported) return original.disconnect.call(this);
      this.track = null; this.paint();
    };
  }
  const section = make('section'); section.id = 'nexus-app-controls';
  section.append(make('h3', '', 'Nexus Remote'));
  const rows = make('div', 'glass rows'); section.append(rows);
  const rowText = (title, subtitle) => {
    const text = make('span', 'rt', title); text.append(make('small', '', subtitle));
    return text;
  };
  const volume = make('button', 'row'); volume.type = 'button';
  volume.setAttribute('role', 'switch');
  volume.append(rowText('TV volume buttons', 'Also works outside the app and on the lock screen while the TV is playing.'));
  const value = make('span', 'rv', 'Off'); volume.append(value, make('i', 'htog'));
  volume.onclick = () => send(volume.getAttribute('aria-checked') === 'true' ? 'stop' : 'start');
  rows.append(volume);
  const error = make('p', 'note'); error.setAttribute('role', 'status');
  for (const [title, subtitle, action] of [
    ['TV address', 'Connect this app to another TV', 'address'],
    ['Back to Nexus', 'Computer remote, writing and media controls', 'exit'],
  ]) {
    const button = make('button', 'row'); button.type = 'button';
    button.append(rowText(title, subtitle), make('i', 'chev'));
    button.onclick = () => send(action); rows.append(button);
  }
  section.append(error); access.after(section);
  // TV connection loss disables TV-action buttons. Host navigation must still
  // work, especially on iPhone where there is no Android Back button.
  const hostButtons = Array.from(rows.children);
  const keepHostControls = () => {
    for (const button of hostButtons) {
      const disabled = button === volume && !!native.busy;
      if (button.disabled !== disabled) button.disabled = disabled;
    }
  };
  if (typeof MutationObserver === 'function') {
    new MutationObserver(keepHostControls).observe(rows,
      {attributes: true, attributeFilter: ['disabled'], subtree: true});
  }
  const pairing = document.querySelector('#pair .pair-card');
  if (pairing) {
    const footer = make('p', 'meta');
    for (const [title, action] of [['TV address', 'address'], ['Back to Nexus', 'exit']]) {
      const button = make('button', 'quiet', title); button.type = 'button';
      button.onclick = () => send(action); footer.append(button);
    }
    pairing.append(footer);
  }
  window.NexusNative = {
    update(state) {
      native = state;
      keepHostControls();
      if (media) media.paint();
      volume.hidden = !state.supported;
      volume.disabled = !!state.busy;
      volume.setAttribute('aria-checked', String(!!state.enabled));
      value.textContent = state.busy ? 'Connecting…' : state.enabled ? 'On' : 'Off';
      error.textContent = state.error || '';
      error.hidden = !state.error;
    },
  };
  send('status');
})();
