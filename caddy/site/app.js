/* The Thorby Media Server — landing page behaviour.

   Three jobs: build the links, report what is reachable, and light the tile
   under the pointer. No dependencies and no build step.

   Loaded as a plain synchronous <script> at the end of <body>, deliberately:
   with `defer` the tiles would sit at href="#" for a few milliseconds after
   they are visible and clickable. Same timing as the inline block it replaces. */

(() => {
  'use strict';

  // Every link on this page is a subdomain of the host serving it, so all of
  // them are built the same way and none of them is written down. One file works
  // unchanged whatever name the page is reached under.
  //
  // This loop used to be scoped to .tiles, because the admin chips were not
  // proxied: their hrefs were <lan-ip>:<port> rendered server-side, and this
  // would have overwritten them with URLs that resolved nowhere. D34 routed them
  // through Caddy, so they are ordinary subdomains now and the exception is gone.
  //
  // That also repairs the compromise D31 had to record. href and probe were two
  // different URLs, because a page served over HTTPS cannot fetch an
  // http://<lan-ip>:<port> URL — blocked as active mixed content whatever
  // `mode: 'no-cors'` claims — so the dots either followed the links and went
  // dark indoors, or attested to a URL that was not the one under them. Every
  // link is https on a real certificate now, so a dot means the thing beneath it
  // answered, which is what anyone reading it assumed all along.
  for (const el of document.querySelectorAll('[data-sub]')) {
    el.href = `${location.protocol}//${el.dataset.sub}.${location.host}`;
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
    // Probing exactly what is linked. There was a data-probe indirection here
    // while the two could differ; since D34 they cannot.
    const up = await Promise.all(links.map((el) => probe(el.href)));

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
