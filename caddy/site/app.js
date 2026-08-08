/* The Thorby Media Server — landing page behaviour.

   Three jobs: build the links, report what is reachable, and light the tile
   under the pointer. No dependencies and no build step.

   Loaded as a plain synchronous <script> at the end of <body>, deliberately:
   with `defer` the tiles would sit at href="#" for a few milliseconds after
   they are visible and clickable. Same timing as the inline block it replaces. */

(() => {
  'use strict';

  // The two public tiles are built from the current host rather than hardcoded,
  // so this one file works unchanged at media.thorby.tech and at a dev sslip.io
  // name — the port comes along for free, which a server-side template using
  // PUBLIC_DOMAIN would lose.
  //
  // Scoped to .tiles on purpose. The admin chips are not subdomains of anything
  // and are not proxied: their hrefs are <lan-ip>:<port>, rendered server-side
  // from the environment, and this loop would overwrite them with URLs that
  // resolve nowhere.
  for (const el of document.querySelectorAll('.tiles [data-sub]')) {
    el.href = `${location.protocol}//${el.dataset.sub}.${location.host}`;
  }

  /* ── Reachability ─────────────────────────────────────────────────────────
     A no-cors request yields an opaque response: status is unreadable, so the
     fact that it resolved at all is the entire signal. That is a real limit
     worth knowing — a 401 login page, a 404 and Caddy's own 502 for a stopped
     container all resolve. The dot means "this hostname is answering", not
     "this app is healthy" (decisions.md D24).

     What it does catch: a route that has drifted out of sites.caddy, a client
     that has dropped off the tailnet, and broken MagicDNS.

     Each failure logs a network error in devtools. That is unavoidable with
     fetch and does not mean the page is broken. */

  const PROBE_TIMEOUT = 3500;   // a phone on cellular needs more than a second

  function probe(url) {
    // AbortController rather than AbortSignal.timeout(), which needs iOS 16.
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), PROBE_TIMEOUT);
    return fetch(url, {
      mode: 'no-cors',
      method: 'HEAD',
      cache: 'no-store',      // a stale opaque hit would mask a real outage
      signal: ctl.signal,
    }).then(() => true, () => false)
      .finally(() => clearTimeout(timer));
  }

  async function probeGroup(container) {
    const links = [...container.querySelectorAll('[data-sub]')];
    const up = await Promise.all(links.map((el) => probe(el.href)));

    // If nothing in the group answered, the instrument itself is not working —
    // no tailnet, an untrusted dev certificate, an offline client — so report
    // nothing rather than painting a wall of grey that blames the services.
    if (!up.some(Boolean)) {
      container.dataset.probes = 'unreliable';
      return;
    }

    links.forEach((el, i) => {
      el.querySelector('.dot').dataset.state = up[i] ? 'up' : 'down';
      el.querySelector('[data-status]').textContent =
        up[i] ? '— responding' : '— not responding';
    });
  }

  probeGroup(document.querySelector('.tiles'));

  // The six admin tools are only probed once someone opens the drawer, which
  // saves six cross-origin requests on the household visits that never do.
  //
  // Guarded because the drawer is absent entirely for clients off the LAN and
  // off the tailnet — Caddy templates it out. Without the guard this throws and
  // takes the spotlight code below with it, on the one page that must never
  // look broken.
  const manage = document.querySelector('.manage');
  if (manage) {
    manage.addEventListener(
      'toggle', () => probeGroup(document.querySelector('.admin')), { once: true },
    );
  }

  /* ── Pointer spotlight ──────────────────────────────────────────────────── */

  if (matchMedia('(hover: hover)').matches &&
      !matchMedia('(prefers-reduced-motion: reduce)').matches) {
    for (const tile of document.querySelectorAll('.tile')) {
      tile.addEventListener('pointermove', (e) => {
        const box = tile.getBoundingClientRect();
        tile.style.setProperty('--mx', `${e.clientX - box.left}px`);
        tile.style.setProperty('--my', `${e.clientY - box.top}px`);
      });
    }
  }
})();
