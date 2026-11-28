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

### iOS (native UI)

iOS is native SwiftUI and does not load the React console, so it has its own implementation:

| File | What it does |
|---|---|
| `ios/Airhand/Core/Account.swift` | account-api client (`URLSession`) plus an `@Observable` `Account`: sign-in, token, device list, credential fetch, self-registration, 45 s sync |
| `ios/Airhand/UI/AccountSection.swift` | the "Account" block on the home tab: a sign-in card, then the account device list above "My devices" |
| `ios/Shared/SharedStore.swift` | `BuildDefaults.accountAPI` reads `AirhandAccountAPI` from Info.plist |
| `ios/Airhand/Core/AppModel.swift`, `App.swift` | starts syncing when already signed in; refreshes on foreground, stops in background |

Login state lives in `account.json` inside the App Group (server address, token, username, this device's uuid), separate
from "My devices".

**Self-registration**: the control code comes from the live host when sharing, otherwise from the saved one
(`SavedHostCode`), so a phone that isn't sharing still shows up for other devices — just as offline. The pairing code only
exists after sharing once (the broadcast extension writes it into `pairing.json`); a phone that never shared can't
register, and the UI says "start sharing on the Share tab once".

The address works like the desktop: `account.json` first, then `AirhandAccountAPI` baked into Info.plist at build time
(`scripts/build-ipa.sh` passes `AIRHAND_ACCOUNT_API` to xcodebuild).

## The desktop CSP (the one that's easy to miss)

`connect-src` in `client/src-tauri/tauri.conf.json` used to allow only self, IPC and `ws://127.0.0.1:*` —
**no http address at all**. The Tauri window loads that policy, so the request is killed by the webview
before it leaves the app:

```
Refused to connect ... violates Content Security Policy directive "connect-src ..."
```

`fetch` just throws a `TypeError`, the UI says "can't reach the account server", and the server log stays
empty — identical to gotcha 3 below, but a completely different cause. `connect-src` now ends with
`http: https:`.

It's a wildcard rather than a fixed address because the account server address is editable in the login
page (so a LAN IP change doesn't need a rebuild) and the build can't know the host. The trade-off is that
this window may request any http/https URL — fine for a self-hosted remote-control tool, but don't load
third-party pages in it.

The browser console is unaffected; `index.html` has no CSP meta tag.

## Three plain-HTTP gotchas

The account server usually lives on a LAN, so `http://` is fine — but the OS may block it:

- **Android 9+**: add `android:usesCleartextTraffic="true"` to `<application>` in `AndroidManifest.xml`
  (Android doesn't have accounts yet; add it together with that work)
- **iOS**: an ATS exception in `Info.plist`. `ios/project.yml` sets `NSAppTransportSecurity →
  NSAllowsArbitraryLoads = true`, because exception domains (`NSExceptionDomains`) can't hold an IP and the account
  server *is* `http://192.168.x.x:8080`. Tighten it by serving https or giving the server a hostname
- **CORS**: requests come from `tauri://localhost`; `account-api` already sends `Access-Control-Allow-Origin`
  (token-only auth, no cookies, so `*` is fine)

All three fail as "network error" with nothing in the server log — check these first.

## Security

- The password is sent once, at sign-in; the client never stores it
- The token is self-signed with HMAC-SHA256 and has no expiry; rotating `TOKEN_SECRET` invalidates every client at once
- Pairing codes are stored AES-256-GCM encrypted, and the list endpoint never returns them; rotating `DEVICE_SECRET`
  makes every stored code undecryptable (all devices must pair again). Back up both secrets with `account-data/`

## When a device shows up in the list

The list holds machines you can *connect to*, not machines that have signed in — a device needs a control code
and a pairing code before it can be dialled.

- **Desktop**: both are fixed and live in `config.toml` (`[code]`, and `pairing` under `[host]`). After signing in,
  the console registers them every 45 seconds. On macOS / Linux the host pauses while the console is open (see
  `HOST_WITH_CONSOLE` in `client/src-tauri/src/status.rs`), so the values come from the config file instead — the
  computer still appears in the list, marked offline, and becomes connectable once you close the console (tapping it
  waits instead of failing). While not hosting it registers only once: each register refreshes `last_seen`, and
  refreshing forever would make other devices believe it is online.
- **iOS**: the phone only has a control code after "Share this device" has run a broadcast at least once. A phone
  that never shared has no identity to register, and the UI says so.

Keep this in mind when touching the code: the desktop registration loop runs inside the console web page, and on
macOS / Linux closing the console destroys that window (and the loop with it) — you cannot count on registering
after the host comes up, only while the console is alive.
