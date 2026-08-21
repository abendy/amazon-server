# Private phone access

The local AMPAS, Guilds, and RSVP sites use stable dev hostnames for phones
connected to the Docker host's Tailscale network. This is a development path;
it does not publish the sites or database ports to the public internet.

## Prerequisites

- The Docker host is running Tailscale and is enrolled in the tailnet.
- The phone is enrolled in the same tailnet and Tailscale is enabled while on
  cellular data.
- The tailnet policy allows the phone to reach the Docker host.
- The local stack and shared nginx gateway are running with this server config.

## DNS

Create public DNS A records in the `amazonmgmstudiosawards.com` zone — either
one wildcard or three explicit records (equivalent; the live setup uses three
explicit records, created 2026-08-21):

| Type | Name | Value |
| --- | --- | --- |
| A | `*.dev` (or `ampas.dev`, `guilds.dev`, `rsvp.dev`) | The Docker host's current Tailscale IPv4 address |

Either form yields these three names:

- `ampas.dev.amazonmgmstudiosawards.com`
- `guilds.dev.amazonmgmstudiosawards.com`
- `rsvp.dev.amazonmgmstudiosawards.com`

The record points to the host's tailnet address, so the names are useful only
from a device that can route through Tailscale. Update the record if that
address changes.

## Phone checks

Open these URLs from the enrolled phone:

- AMPAS: <http://ampas.dev.amazonmgmstudiosawards.com>
- Guilds: <http://guilds.dev.amazonmgmstudiosawards.com>
- RSVP admin: <http://rsvp.dev.amazonmgmstudiosawards.com/admin/>

For RSVP, also check the built embed at
<http://rsvp.dev.amazonmgmstudiosawards.com/rsvp/consideramazon/>. The RSVP
root may return its expected `403`; use `/admin/` and the embed path for the
route checks.

The Vite development server on port `5174` remains private and is not exposed
by this hostname setup.

## Troubleshooting

**"This site can't be reached" / `ERR_CONNECTION_FAILED` on a dev hostname:**
the gateway serves plain HTTP only — nothing listens on 443. Mobile browsers
that auto-upgrade to HTTPS (Brave Shields, Chrome HTTPS-First mode) hit the
closed port and fail before any request is sent. Type the `http://` scheme
explicitly, or allow the site to load over HTTP / disable the HTTPS upgrade
for these hostnames. Confirmed on iOS Brave, 2026-08-21.
