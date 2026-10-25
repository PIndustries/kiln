import Foundation

extension WebApplication {
    // Opt-in development pages poll independently of live-view leases, including
    // controller-rendered pages and releases whose old sockets remain open.
    var developmentClient: String {
        """
        (() => {
          const instance = '\(instance)';
          let stopped = false;
          window.addEventListener('pagehide', () => { stopped = true; });
          async function check() {
            if (stopped) return;
            const controller = new AbortController();
            const deadline = setTimeout(() => controller.abort(), 3000);
            try {
              const response = await fetch('/__kiln/instance', {cache:'no-store', credentials:'same-origin', signal:controller.signal});
              const current = response.ok ? await response.json() : null;
              if (current && typeof current.instance === 'string' && current.instance !== instance) {
                stopped = true; location.reload(); return;
              }
            } catch { /* Keep the current page during a failed build or restart. */ }
            finally { clearTimeout(deadline); }
            if (!stopped) setTimeout(check, 1000);
          }
          setTimeout(check, 1000);
        })();
        """
    }

    static let browserClient = #"""
    (() => {
      const root = document.getElementById('kiln-live');
      if (!root) return;
      const status = document.getElementById('kiln-live-status');
      const drafts = new Map();
      let socket, ready = false, sequence = 0, retries = 0, stopped = false;
      function connect() {
        ready = false;
        const url = new URL('/__kiln/live/' + root.dataset.ticket, location.href);
        url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
        socket = new WebSocket(url);
        socket.onmessage = event => {
          let update;
          try { update = JSON.parse(event.data); } catch { socket.close(); return; }
          if (update.version !== 1 || !Number.isSafeInteger(update.sequence) || typeof update.html !== 'string') { socket.close(); return; }
          sequence = ready ? Math.max(sequence, update.sequence) : update.sequence;
          const active = root.contains(document.activeElement) ? document.activeElement : null;
          const focused = active?.id, start = active?.selectionStart, end = active?.selectionEnd;
          root.innerHTML = update.html;
          for (const [id, draft] of drafts) {
            const input = document.getElementById(id);
            if (input && root.contains(input) && input.name === draft.name) {
              if (input.type === 'checkbox' || input.type === 'radio') input.checked = draft.checked;
              else input.value = draft.value;
            }
          }
          const restored = focused && document.getElementById(focused);
          if (restored) { restored.focus(); if (start != null && restored.setSelectionRange && !['number','email','checkbox','radio'].includes(restored.type)) restored.setSelectionRange(start, end); }
          ready = true; retries = 0; status.textContent = 'Live · connected';
        };
        socket.onclose = async () => {
          ready = false;
          if (stopped) return;
          status.textContent = 'Disconnected · refreshing server state; unsent actions are not replayed';
          if (++retries > 6) { status.textContent = 'Live session unavailable · reload this page'; return; }
          setTimeout(connect, Math.min(5000, 250 * 2 ** retries));
        };
        socket.onerror = () => socket.close();
      }
      function send(name, values) {
        if (!ready || socket.readyState !== WebSocket.OPEN) { status.textContent = 'Disconnected · action not sent'; return; }
        const encoded = JSON.stringify({sequence: sequence + 1, name, values, csrf: root.dataset.csrf});
        if (new TextEncoder().encode(encoded).length > 16384 || socket.bufferedAmount > 16384) { status.textContent = 'Action too large or connection busy'; return; }
        sequence++; socket.send(encoded); return true;
      }
      root.addEventListener('input', event => {
        const input = event.target;
        if (input.id && input.name && input.type !== 'file') drafts.set(input.id, {name: input.name, value: input.value, checked: input.checked});
      });
      root.addEventListener('click', event => {
        const target = event.target.closest('[data-kiln-click]');
        if (!target || !root.contains(target)) return;
        event.preventDefault(); send(target.dataset.kilnClick, {value: target.dataset.value || ''});
      });
      root.addEventListener('submit', event => {
        const form = event.target.closest('form[data-kiln-submit]');
        if (!form) return;
        event.preventDefault();
        const values = Object.create(null);
        for (const [key, value] of new FormData(form)) {
          if (typeof value !== 'string' || Object.hasOwn(values, key)) { status.textContent = 'Files and repeated form fields are unsupported'; return; }
          values[key] = value;
        }
        if (send(form.dataset.kilnSubmit, values)) for (const input of form.elements) drafts.delete(input.id);
      });
      window.addEventListener('pagehide', () => { stopped = true; socket?.close(); });
      connect();
    })();
    """#
}
