# Account and account devices (account-api)

[← Back to README](../README.md) · [简体中文](account.zh-CN.md)

Airhand has always been **control-code driven**: a host connects to the relay and gets a 6-digit code, a controller types
that code to reach it, and "My devices" is just a local list in this computer's `config.toml` — another computer can't see it.

This build adds an **account layer** on top: sign in once and every online device on the same account is listed; one click
connects, with the pairing code fetched from the server on demand. Typing control codes still works exactly as before.

```
host A ──┐                        ┌── controller B (signed in, sees A and C)
host C ──┴── account-api (yours) ─┘
                 │
        relay server (UDP 4433, not involved)
```

The account server only stores **device metadata plus encrypted pairing codes**. It is not part of Airhand's QUIC transport
or the end-to-end encryption: sessions stay encrypted between the two devices and the server can't see a single byte.

## Server

`account-api/` (Node + SQLite). Endpoints and deployment are documented in its README:

| Endpoint | Purpose |
|---|---|
| `POST /auth/login` | fixed account → a token that never expires |
| `POST /device/register` | a host registers its control code and pairing code (upsert) |
| `POST /device/heartbeat` | keep-alive; 90 s without one means offline |
| `GET /device/list` | devices on the account (never includes pairing codes) |
| `GET /device/credential` | fetch one device's pairing code on demand |

## Client

### Sign-in page

Without a token the whole window is the sign-in page (`client/src/components/LoginView.tsx`): account, password, server.
The token is kept in the webview's localStorage, so the next launch goes straight to the console. **It never expires**;
only "Sign out" (in the settings menu) removes it.

Where the server address comes from, highest priority first:

1. Typed on the sign-in page (saved in localStorage) — change the NAS IP without rebuilding
2. `VITE_AIRHAND_ACCOUNT_API` baked in at build time (the `AIRHAND_ACCOUNT_API` secret in
   `.github/workflows/build-airhand.yml`)
3. Neither: the sign-in page expands the address field and makes you fill it in

The format must be `http(s)://host:port` with no path.

### Account devices

The new-connection tab grows an "Account devices" section above "My devices"
(`client/src/components/AccountDevices.tsx`): devices, control codes, online state, last seen. One click connects — the
pairing code is fetched at that moment (`GET /device/credential`) and never stored locally. If it can't be fetched (the
pairing code was rotated, or the stored one is stale) Airhand falls back to its normal flow and asks you for the code.

Offline devices are clickable too: the connection waits on the server and opens as soon as the device comes back, exactly
like reconnecting from "My devices".

### Registering this computer

Every 45 s the console registers this computer and refreshes the device list (`startAccountSync` in
`client/src/lib/actions.ts`). Registration needs this computer's **control code and pairing code**, which used to be
tray-only, so there is a new Rust command `host_identity` (`src-tauri/src/lib.rs`) that hands them to the console.

**Limitation**: those two only exist while the host is connected to the relay. On macOS and Linux the host stops while the
console is open, so registering this computer only succeeds after switching back to host mode. On Windows the host always
runs (service or in-process), so it works directly. The UI says "this computer isn't registered yet" with a retry button.

## Two plain-HTTP gotchas

The account server usually lives on a LAN, so `http://` is fine — but the OS may block it:

- **Android 9+**: add `android:usesCleartextTraffic="true"` to `<application>` in `AndroidManifest.xml`
- **iOS**: an ATS exception in `Info.plist` (`NSAllowsLocalNetworking` or `NSAllowsArbitraryLoads`)
- **CORS**: requests come from `tauri://localhost`; `account-api` already sends `Access-Control-Allow-Origin`
  (token-only auth, no cookies, so `*` is fine)

All three fail as "network error" with nothing in the server log — check these first.

## Security

- The password is sent once, at sign-in; the client never stores it
- The token is self-signed with HMAC-SHA256 and has no expiry; rotating `TOKEN_SECRET` invalidates every client at once
- Pairing codes are stored AES-256-GCM encrypted, and the list endpoint never returns them; rotating `DEVICE_SECRET`
  makes every stored code undecryptable (all devices must pair again). Back up both secrets with `account-data/`
