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
  //
  // Where the tile is going and what gets probed are two different URLs now,
  // and that is deliberate (decisions.md D31):
  //
  //   href    data-lan when Caddy rendered one — a client on the LAN or the
  //           tunnel goes straight to http://<lan-ip>:<port> rather than out
  //           to the public name and back in through the router.
  //   probe   always the public name, because the probe cannot follow. This
  //           page is served over HTTPS and a fetch from an https: origin to
  //           an http: URL is blocked as active mixed content whatever
  //           `mode: 'no-cors'` says — the same wall the Manage chips hit. If
  //           the dots followed the links they would simply go dark indoors.
  //
  // The cost, stated plainly because nothing else will say it: the dot attests
  // to the public path, not to the link under it. A wrong ADMIN_HOST or an
  // unpublished port shows green. What it still catches is what it always
  // caught — a route that has drifted out of sites.caddy, a client off the VPN,
  // a stale DNS answer.
  for (const el of document.querySelectorAll('.tiles [data-sub]')) {
    const derived = `${location.protocol}//${el.dataset.sub}.${location.host}`;
    el.dataset.probe = derived;
    el.href = el.dataset.lan || derived;
  }

  /* ── Reachability ─────────────────────────────────────────────────────────
     A no-cors request yields an opaque response: status is unreadable, so the
     fact that it resolved at all is the entire signal. That is a real limit
     worth knowing — a 401 login page, a 404 and Caddy's own 502 for a stopped
     container all resolve. The dot means "this hostname is answering", not
     "this app is healthy" (decisions.md D24).

     What it does catch: a route that has drifted out of sites.caddy, a client
     that has dropped off the VPN, and a stale DNS answer.

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
    // data-probe only exists on the hero tiles, where it may differ from href.
    // The admin chips have nothing to fall back to, so they probe what they link.
    const up = await Promise.all(links.map((el) => probe(el.dataset.probe || el.href)));

    // If nothing in the group answered, the instrument itself is not working —
    // no VPN, an untrusted certificate, an offline client — so report
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

  // The nine admin tools are only probed once someone opens the drawer, which
  // saves nine cross-origin requests on the household visits that never do.
  //
  // Guarded twice.
  //
  // The drawer is absent entirely for clients off the LAN and off the tunnel —
  // Caddy templates it out. Without that guard this throws and takes the
  // spotlight code below with it, on the one page that must never look broken.
  //
  // And the probes cannot work over HTTPS at all. This page is served only at
  // PUBLIC_DOMAIN, where Caddy redirects :80 to :443, while the admin chips
  // point at http://<lan-ip>:<port> — nothing proxies them and there is no
  // certificate for a private address. A fetch from an https: origin to an
  // http: URL is blocked as active mixed content whatever `mode: 'no-cors'`
  // says, so all nine would reject, the group would be marked unreliable and
  // the dots hidden. The visible result is identical either way; skipping is
  // honest about it and keeps the console clean. Clicking the chips is
  // unaffected — that is a navigation, not a subresource.
  //
  // This is exactly the wall the hero tiles' data-probe exists to step around:
  // they have a public https name to probe instead, and the chips never did.
  const manage = document.querySelector('.manage');
  const admin = document.querySelector('.admin');
  if (manage && admin) {
    if (location.protocol === 'https:') {
      // Hide the dots outright rather than leaving them at their default grey.
      // Skipping the probe alone would paint nine "unknown" dots that no
      // longer mean anything, which is the wall of grey probeGroup avoids.
      admin.dataset.probes = 'unreliable';
    } else {
      manage.addEventListener('toggle', () => probeGroup(admin), { once: true });
    }
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
