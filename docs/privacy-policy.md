# Privacy Policy for Noteesek

**Last updated: 17 June 2026**

Noteesek ("the app") is a notes application developed by Martin Hromádka ("we",
"us"). This policy explains what happens to your data when you use the app.

## The short version

Noteesek is **self-hosted and privacy-first**. We do **not** run any central
server, and we do **not** collect, receive, store, or have access to any of your
data. The app contains **no analytics, no advertising, and no third-party
tracking**.

Your notes stay either on your device or on a server **you** choose and control.

## How the app stores your data

Noteesek behaves differently on each platform:

- **Android (mobile): local-first.** The app works fully offline with **no
  account required**. Your notes, checklists, labels, notebooks, note colours,
  and image attachments are stored **only in a local database on your device**.
  Nothing leaves your device unless you choose to connect a server (see below).
- **Web:** the web version is served by, and talks to, a self-hosted server.
  Using it requires signing in to that server, and your data lives on that
  server.

### Connecting a server (optional sync)

On mobile you may optionally connect the app to a **PocketBase server that you or
a third party you trust operates**. When you do:

- The app sends your notes and related data to **that server only**, to keep your
  devices in sync.
- To sign in, the app sends an **email address and password** to that server for
  authentication.
- The server address is one **you enter yourself**. The app never sends your data
  to any address you did not configure.

We (the app's developer) are not a party to this connection and never receive
your data. The operator of the server you connect to is responsible for how that
server handles your data.

## What data the app handles

Depending on how you use it, the app handles:

- **Note content** you create: titles, text, checklist items, note colours,
  labels, and notebook names.
- **Image attachments** you add to notes.
- **Account credentials** (email and password) — only when you choose to use an
  account/sync, and only sent to the server you configured.

The app does **not** collect your contacts, location, device identifiers,
advertising IDs, or usage analytics.

## Device permissions

The app requests only the permissions it needs to function:

- **Internet access** — to reach the server you configure (sync on mobile, or the
  web app's own server). If you never connect a server on mobile, the app still
  works fully offline.
- **Photos / media access** — only when you add an image attachment to a note, so
  you can pick an image. Selected images are stored with your notes.
- **Sharing (receive shared content)** — so you can share text or images from
  other apps into Noteesek to create a note ("quick capture").
- **Biometric / device unlock** — only if you enable the optional app lock, to
  unlock the app with your fingerprint/face or PIN. This is handled by your
  device's operating system; the app never receives or stores your biometric data.

## Network and security notes

- The app can connect to servers over plain **HTTP** as well as HTTPS, because
  self-hosted servers are often reached over a local network or without a
  certificate. You choose the server and connection. For data in transit, we
  recommend you use an HTTPS server address where possible.
- Image attachments on a server are stored as protected files that require a
  short-lived access token to download.
- The security of any server you connect to — including encryption, backups, and
  access control — is the responsibility of whoever operates that server.

## Data sharing with third parties

We do not share your data with anyone, because we never receive it. The app
contains no third-party SDKs that collect data. The only place your data is sent
is the server **you** explicitly configure.

## Data retention and deletion

You are always in control of your data:

- **On-device data** can be removed by deleting notes, emptying the Trash, using
  the in-app "Wipe data" option, or uninstalling the app.
- **Server data** can be removed from within the app (delete notes / "Wipe data")
  or by the server operator directly.
- You can also export your notes (Markdown or JSON backup) at any time.

Because we do not hold your data, requests to access or delete data must be
directed to the operator of the server you use.

## Children's privacy

Noteesek is not directed to children under 13 and does not knowingly collect any
personal information from anyone, including children.

## Changes to this policy

We may update this policy from time to time. Material changes will be reflected by
updating the "Last updated" date above and publishing the new version at the same
location as this document.

## Contact

If you have questions about this privacy policy, contact:

**Martin Hromádka** — martin.hromadka@outlook.com
