# Applications and CI: the plan

2026-10-27: distributing builds is an app of its own, Applications, with a
small server of its own, Applications Server, which depends on no other.
Builds and releases come only from CI, on the owner's self-hosted runner,
which leases containers and VMs from OS Server as it needs them. Agents
still lease machines for their own checks, but nothing they make by hand is
trusted: only what CI produced.

## 1. Applications

**Applications.app** (`com.LoganShire.Applications`): iPhone, iPad and Mac.
Its one job is handing out builds of the owner's apps.

- The main list is by bundle id. Every app is a `com.LoganShire.*` id, and
  the server refuses any other.
- Under each app are two kinds of build:
  - **commit builds**, from a branch, a pull request or main, labelled with
    their commit and where it came from;
  - **releases**, production builds; commit builds are betas, which
    install beside them (`com.LoganShire.<App>.Beta`, docs/VARIANTS.md).
- It installs, opens and notifies.
- Android, the web, Linux and Windows on Isomer come later.

**Applications Server.app** (`com.LoganShire.ApplicationsServer`): a menu
bar app, as Visor Server is, around the same server that runs as a command
line, `applications-server`, the Swift binary alone, on macOS or Linux.

- libraries/applications_server and server/ (`applications-server`):
  publishing, channels, APNs, connection codes, over-the-air installs and
  the inbox.
- Its own names:
  - the certificate authority is "Applications", so its certificate is
    "Applications CA (<host>)", installed once from
    `Applications.mobileconfig`;
  - the data lives in ~/Library/Application Support/Applications, or
    `$XDG_DATA_HOME/applications` on Linux;
  - the launch agent is `com.LoganShire.ApplicationsServer`.
- **Linux** needs the Apple-only pieces replaced:
  - the HTTP and TLS listener (Network, Security);
  - making the certificate authority (Security, /usr/bin/openssl);
  - SystemConfiguration's host name and CoreImage's QR code.

  APNs (CryptoKit) moves to swift-crypto, and so does the check of CI's
  tokens (Security's RS256). Signing (codesign, notarytool, behind
  `CodeSigning` and `Notarizing`) moves to rules_applecross's tools, which
  sign and notarize Apple's code from Linux.
- **On ports of its own** (7460 and 7461), as a launchd service of its
  own.

**Install detection** (in the server and the app; docs/SERVER.md, "What
is installed"). A build carries `applications-<release>-build-<1…49>://`,
the release being Applications' (MAJOR.MINOR of its version). Numbers
belong to one release and are never given again; 50 is held back as the
guard.
- Applications no longer asks iOS about build schemes (2026-11-02): it
  lists the apps' own link schemes (`LSApplicationQueriesSchemes`), and an
  app's record in the shared database says which build is installed
  (docs/SERVER.md, "What is installed"). The server still numbers and
  stamps production builds until every app records itself.
- The server's current release is that of the newest Applications iPhone
  build it has published, or its own before the first. It gives other
  apps' builds the next number of that release. When 49 are out, it gives
  no more (and publishes nothing that needs one) until an Applications
  build of a newer release is published; Applications' builds are always
  accepted. In practice Applications is updated well before that.
- **The scheme goes in as the build is signed.** The server signs every
  build CI sends (section 2), and adds the scheme as it signs a release's
  iPhone build. CI may still stamp it at build time (`applications-server
  scheme <bundle id> --commit <sha>`, or `POST /api/build-scheme`).
  Nothing published by hand is production.
- A build made under an earlier release keeps that release's scheme, so a
  newer Applications can't see it as installed until that app's next
  build. The design accepts that.
- This replaces the single pool of 25 schemes shared by every app, where a
  scheme still held by an older install made Visor 0.41.15 look installed
  (it was the Storybook's).

## 2. CI: the only source of proofs and builds

Every repository gets the same workflow on the owner's self-hosted runner. Each
job leases what it needs from OS Server: a container for Linux builds, a
macOS VM for the Apple apps (built unsigned: the server signs them),
simulators and emulators for proofs.

- **A pull request:**
  - builds every platform;
  - publishes commit builds to Applications (the pull request's, pruned
    when it closes);
  - runs the **abbreviated proof**, kept as the run's artifacts, with a
    check summarising it.
- **A push to main:**
  - builds;
  - publishes main's commit builds;
  - runs the **complete proof**, compared screen by screen with the last
    release's.
- **A release** (2026-10-28; docs/CI.md):
  - an agent or CI drafts a GitHub release on one main commit, the proof
    attached, so the next release compares against a baseline that doesn't
    expire;
  - **approving it is publishing its tag:** the owner looks at the proof and
    publishes the draft on GitHub, which makes `vX.Y.Z`;
  - the tag starts the repository's release job, if it has apps, which
    builds with `--config=prod`, unsigned, in a macOS VM lease;
  - it publishes to Applications with its GitHub Actions OIDC token, which
    says the run is a release of that tag by the owner; Applications Server
    checks it, signs the builds and publishes them as production. That
    is the only way a build becomes production: the server asks no other
    server first, and promotes nothing after.
- **Signing is Applications Server's.** CI never holds a signing key, a
  notary key or the server's password: the identities are in the server
  Mac's keychain, the profiles in its data folder, the App Store Connect
  key in its settings. The server signs a beta with the development
  identity and a release with the production one (ad hoc profiles where
  it has them), and signs and notarizes every Mac app, betas too.
  - It takes a token from a configured repository only, for that
    repository's bundle ids (and their `.Beta`): one repository never
    publishes another's app.
  - A release is a `v*` tag's run, released or pushed by a releaser
    (`applications-server releaser AttilaTheFun`); a tag anyone else made is
    refused. Anything else from a configured repository is a beta.
- **No GitHub environments.** A private repository on the owner's plan can't
  protect one with a required reviewer, so the approval is the release's
  publication, and the server checks who published it.
- **Version numbers** still come from the server, so every build of a
  commit has one number: CI asks with its token (`POST /api/next-version`,
  tools/ci/next_version.sh), as `next-version --commit` does on its Mac.
- **Later:** TestFlight and the App Store, from the same release job,
  signed by the server too.
- **Agents** push branches and open pull requests. They don't file proofs
  or publish builds themselves.

## The order

1. Applications Server, on macOS, with its own certificate authority and
   the schemes stamped at build time. Done.
2. Applications.app. Done.
3. The CI workflow, on one repository first. Done.
4. Every other repository that publishes builds moved onto it.
5. Applications Server on Linux.
6. TestFlight and the App Store.

## Decided (2026-10-27)

- **Repository:** Applications is its own repository,
  AttilaTheFun/applications, with the networking and certificate libraries
  it stands on.
- **Commit builds:**
  - a branch's latest build replaces its previous one, and goes when the
    branch merges;
  - main's builds last until tagged into a release;
  - released builds last indefinitely.
