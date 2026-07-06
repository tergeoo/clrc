# Remote access (Mac at home, iPhone anywhere)

By default the relay speaks **ws:// without TLS** — fine on your home Wi-Fi, but
its secrets (login password, JWT, agent secret) travel in cleartext. To use clrc
from cellular / another network you must add encryption. Pick **one** of the
options below. They are ordered by how much I recommend them for a single-user
setup with the Mac at home.

Whatever you pick, the relay's own hardening still applies (login rate-limit,
connection caps, session-id validation, home-dir-confined file browser).

---

## Option 1 — Tailscale (recommended)

Your Mac and iPhone join a private WireGuard mesh. The relay stays on the Mac and
is **never exposed to the public internet** — so the brute-force / DoS attack
surface disappears entirely, and traffic is end-to-end encrypted. No TLS certs,
no code, free for personal use.

**Setup**
1. Install Tailscale on the Mac (`brew install --cask tailscale` or the App
   Store app), sign in.
2. Install Tailscale on the iPhone (App Store), sign in with the **same account**.
3. On the Mac, find its tailnet address: `tailscale ip -4` (looks like
   `100.x.y.z`), or enable **MagicDNS** and use the Mac's name.
4. In the iPhone app's login screen, set the relay URL to
   `http://100.x.y.z:8080` (the Mac's Tailscale IP). It works from anywhere the
   phone has Tailscale on.

**Trade-off:** the Tailscale app must be running/connected on the phone. That's
it. This is the smallest, safest setup for your topology.

> Note: leave the relay on plain `http://…:8080`. Tailscale already encrypts the
> link end-to-end; you do **not** need native TLS on top of it.

---

## Option 2 — Cloudflare Tunnel

Puts a public `https://…` (and thus `wss://…`) in front of the Mac's relay with
TLS handled by Cloudflare — no home-router port-forwarding, no cert management.

**Setup**
1. `brew install cloudflared`, then `cloudflared tunnel login`.
2. `cloudflared tunnel --url http://localhost:8080` for a quick
   `https://<random>.trycloudflare.com`, **or** create a named tunnel bound to a
   domain you own (see Cloudflare docs) for a stable hostname.
3. In the iPhone app set the relay URL to the `https://…` hostname. The app
   auto-upgrades `https`→`wss` for the socket.

**Trade-off:** needs a (free) Cloudflare account; the relay is now reachable by
anyone who learns the hostname — but the relay hardening (rate-limit, JWT,
agent secret) is your gate, so keep `ADMIN_PASSWORD` strong.

---

## Option 3 — Relay in the cloud (Railway / fly.io)

Deploy the relay to a cloud host; the platform terminates TLS and gives you a
`https://…up.railway.app`. The home Mac's agent dials **out** to it, the iPhone
connects to it from anywhere. The relay is then always-up, independent of the Mac.

**Setup**
1. Deploy `relay/` (there's `relay/docker/Dockerfile`). Set env vars
   `JWT_SECRET`, `ADMIN_PASSWORD`, `AGENT_SECRET` in the platform dashboard
   (`PORT` is set by the platform).
2. Point the Mac agent's `relay_url` at `wss://<app>.up.railway.app` (or the
   `https` URL — the agent/app handle the scheme).
3. Point the iPhone app at the same `https://…` URL.

**Trade-off:** small monthly cost / free tier; the relay lives on someone else's
box (it only ever relays encrypted-in-transit terminal bytes, never stores them).
No native TLS needed — the platform does it.

---

## Option 4 — Native TLS on a self-hosted relay

If you run the relay on a VPS (or the Mac) with your own domain + certificate,
the relay can serve `https`/`wss` directly. Set both env vars:

```sh
TLS_CERT_FILE=/etc/letsencrypt/live/example.com/fullchain.pem
TLS_KEY_FILE=/etc/letsencrypt/live/example.com/privkey.pem
```

(Get a cert with `certbot`/Let's Encrypt.) The relay then calls
`ListenAndServeTLS`; leave both unset to stay plaintext. This is the most control
and the most manual setup (port-forwarding the home router, dynamic DNS, cert
renewal) — only pick it if the options above don't fit.

---

## Which should I use?

- **Just want it to work securely, Mac at home → Option 1 (Tailscale).**
- Want a public URL without touching your router → Option 2 (Cloudflare Tunnel).
- Want the relay always-up regardless of the Mac → Option 3 (cloud).
- Already self-hosting with a domain + cert → Option 4 (native TLS).
