# Caddy with the Cloudflare DNS module, for ACME DNS-01.
#
# The stack is VPN-only (decisions.md D33). The router forwards the WireGuard
# port and nothing else, so there is no path by which an HTTP-01 challenge
# could ever arrive — Let's Encrypt would be knocking on a port the router
# does not answer. DNS-01 proves control by writing a TXT record in the zone
# instead, which needs no inbound path at all.
#
# That needs a provider module, and Caddy's modules are Go packages compiled
# into the binary, not runtime plugins. Hence a build step, which this repo did
# not previously have — the Caddyfile's own comment used to cite that as the
# reason for choosing HTTP-01. That reasoning held while port 80 was open;
# it stopped holding when it closed.
#
# This builds from Caddy's own official builder image rather than pulling
# someone else's pre-built Caddy. The convention in CLAUDE.md is about not
# trusting a third party's rebuild of an upstream image, and this is upstream's
# documented way to add a module.
#
# The two tags must stay in step: xcaddy compiles against the Go module set of
# the builder, and the result is copied into the matching runtime image.
ARG CADDY_VERSION=2.11

FROM caddy:${CADDY_VERSION}-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:${CADDY_VERSION}-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
