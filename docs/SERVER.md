# Applications Server and Applications

Builds of your own apps, published to Applications Server on your Mac and
installed by Applications, over the air on your iPhone and iPad or in place
on your Macs: each app's betas, built from its commits, and its production
builds, published by its releases, installed side by side
(docs/VARIANTS.md). The server tells the devices of each new build with a
push ("A new Visor build is ready to install"); tapping it opens the build
in Applications.

Applications Server is a launchd service of its own
(`com.LoganShire.ApplicationsServer`), listens on 7460 and 7461, keeps its
data in ~/Library/Application Support/Applications and names its
certificate authority "Applications". It asks no other server anything
before it publishes a build: what a build is, beta or production, is how
it was published (below, "Publishing").

- **libraries/applications_server** — the server: HTTP and HTTPS over
  Network.framework, the published builds (every production build, and of
  the betas each bundle's newest and the week's), install manifests, its
  own certificate authority, pushes through APNs, and the catalog of apps
  and their builds, each on its channel.
- **server** — `applications-server`: `publish` (a beta, by hand),
  `next-version`, `scheme`, `code` (`--ci`
  for CI's), `apns`, `inbox`, `password`, `app`, `repo`, `releaser`,
  `notary`, `oidc`, `status`; `serve`, the server, and
  `install`, `restart` and `uninstall`, its launchd service.
- **Signing is the server's.** CI sends its builds unsigned, with its
  GitHub Actions OIDC token in place of the password; the server checks
  the token, decides what the job may publish (a release the owner published,
  production; anything else, a beta), signs the builds with its Mac's
  identities and profiles, notarizes the Mac apps, and publishes them
  (docs/CI.md; below, "Signing").
- **app** — Applications, for the iPhone, the iPad and the Mac: this
  device's apps beside the one open, each with Install (none of it here),
  Unknown (here, but it hasn't said which build: tapping opens it, and it
  says), Update (it said an older build, of any variant) or Open
  (Applications' own Open does nothing: it is open already) and its newest
  build, its production's or else its beta's, marked Beta; an app's
  production builds and its betas apart, one entry (`<id>` and
  `<id>.Beta`; on a Mac, `<id>.Mac` and `<id>.Mac.Beta`), each build with
  its commit, and its versions.
  Settings (the server) from the list's toolbar. Its icon is an Icon
  Composer document (artwork/app-icon).
- The wire format (builds, the hello, the connection code, a device's push
  registration, the install link, the catalog) is
  `//libraries/applications_protocol`; the connection code and the hello
  are `//libraries/pipeline_client`.

App Transport Security is off in the apps (`NSAllowsArbitraryLoads`): every
request they make is pinned to their server's own authority instead
(ServerTrust), which a Mac or phone need not trust itself, and a tailnet
address (100.x) is not one ATS makes an exception for. (`NSAllowsLocalNetworking`
would turn `NSAllowsArbitraryLoads` off again, so it is not set.)

## How it reaches the devices

The server listens on its LAN and tailnet addresses (HTTPS on 7461; plain
HTTP on 7460 for the certificate profile only). Applications asks every
address at once and uses the LAN's when it answers, the tailnet's
otherwise; when neither answers it says the server can't be reached and to
check the network (away from home, Tailscale must be on).

iOS installs over the air only from HTTPS it trusts, and a LAN or tailnet
IP has no public certificate. So the server is its own certificate
authority, "Applications CA (<the Mac's name>)": it issues itself a
certificate for every address it has (again whenever they change), and the
phone trusts the authority once, from a profile (`Applications.mobileconfig`,
from the server's page on its plain port, in Safari). Applications itself
pins the authority from the connection code, so it works before that.

Builds install over the air when their signing covers the device: a
development or Ad Hoc profile listing it (the team's registered devices).

## Setting up

    bazel run -c opt //server -- install   # the launchd service, started now and at every login
    applications-server apns --key AuthKey_XXXX.p8 --key-id XXXX --team-id XXXX
    applications-server code --qr code.png # scan with the phone's camera, or paste `applications-server code` in Applications

And for CI's builds, which the server signs (below, "Signing"; docs/CI.md):

    applications-server notary --key AuthKey_YYYY.p8 --key-id YYYY --issuer <issuer id>   # App Store Connect's API key
    applications-server releaser AttilaTheFun                     # whose releases are production
    applications-server repo AttilaTheFun/visor com.LoganShire.Visor com.LoganShire.Visor.Mac
    applications-server code --ci                                 # each repository's APPLICATIONS_CI_CODE secret

The server is a launchd service of its own, `com.LoganShire.ApplicationsServer`
(~/Library/LaunchAgents/com.LoganShire.ApplicationsServer.plist):

- `install` copies the running binary into the data folder
  (bin/applications-server), where a rebuilt checkout does not move it,
  and has launchd run it with `serve` at login and whenever it exits, its
  output in ~/Library/Logs/Applications Server/applications-server.log;
  one installed before is stopped and replaced, and the new build starts.
  ~/.local/bin/applications-server is a link to that binary, so the
  commands are the build that serves. Install again to update.
- `restart` stops it and starts it again (`launchctl kickstart -k`), after
  a setting the running server reads only as it starts (`password`,
  `inbox`, `apns`). What CI may publish (`repo`, `releaser`, `oidc`,
  `notary`) is read at each of its publishes, and needs none.
- `uninstall` stops it and removes its plist; the data folder, the binary
  in it and the link stay.
- `status` says whether launchd has it loaded and its pid, whether its
  ports answer on this Mac as this server (or as another, or not at all),
  then what the server has: CI's repositories and releasers, the notary
  key's id, the kinds of identity in the keychain and the profiles' bundle
  ids and kinds (never a team, a certificate's name or a device).

`serve` runs the server in the foreground, as the service does.
`APPLICATIONS_DATA_DIR` puts a server's data elsewhere (a scratch server
beside the real one); installed with it set, the service is given it too.
On Linux there is no service yet: `install`, `restart`, `uninstall` and
`status` say so and fail (docs/APPLICATIONS_PLAN.md, Applications Server on
Linux).

Applications needs a development profile for its one bundle id,
`com.LoganShire.Applications` (every build, Alpha and Production;
docs/VARIANTS.md), with push notifications and the app group
(app/app.entitlements), and the team in an untracked `.bazelrc.user`:
`common --repo_env=PIPELINE_TEAM_ID=<team>`.

    bazel build //app:applications_ios --ios_multi_cpus=arm64 -c opt   # Applications β
    tools/install_mac_app.sh --publish notes.md   # the Mac app's beta, signed, notarized and published
    bazel test //tests/...

The Mac app is notarized when the script is told a notarytool keychain
profile: `APPLICATIONS_NOTARY_PROFILE` (and `APPLICATIONS_NOTARY_KEYCHAIN`,
`APPLICATIONS_NOTARY_KEYCHAIN_PASSWORD_FILE` when the profile is in a
keychain of its own).

Whether the API asks for the password is the server's to say:
`applications-server password off` for a server only your LAN or your own
tailnet reaches.

## Pushes

The server keeps the APNs key itself (apns.p8 beside its settings, and the
key's and team's ids in config.json), not a path to it:
`applications-server apns --key <AuthKey.p8> --key-id <id> --team-id
<team>`, then `applications-server restart`. There is no topic to set:
each device registers its own app's bundle id as its topic, and
Applications registers its own (`com.LoganShire.Applications`). An APNs
key is the team's, for every app of it.

## Mac apps

Publish a Mac app as a .zip with the `.app` at its top (`ditto -c -k
--keepParent App.app App.zip`, or rules_apple's macos_application output)
or as a disk image; the server keeps a .zip. Applications on the Mac reads
what is installed from /Applications itself, by bundle id, so a Mac app
need not say anything: a beta (`<id>.Beta`) is an app of its own, installed
beside its production (as `<name>.app`, or named after its bundle id when
an app of another id has that name). Phones are pushed only their own
builds; Macs ask.

## Android apps

Publish an Android app as its .apk, signed with APK Signature Scheme v2 or
later (an unsigned one, or one signed only with v1, is refused: Android
would not install it). The server reads its compiled AndroidManifest.xml
(the package as the app's id, versionName, versionCode as the build) and
its resources.arsc (the label, and the icon's PNG of the highest density;
an adaptive icon's PNGs of the same name stand for it), and keeps the
signing certificate's SHA-256 as the build's `signer`: Android installs an
update only over an app signed with the same certificate. It is listed by
`/api/apps?platform=android` and downloaded from `/builds/<id>/<key>/app.apk`.
Nothing is pushed for it; an Android app asks (Applications on Android, on
Isomer, comes later).

## Signing

The server signs every build CI sends (docs/CI.md), on its Mac for now
(libraries/applications_server/Sources/Signer.swift): an iPhone app and
all the code in it, inside out, each app and extension with its own
profile and entitlements; a Mac app with Developer ID, notarized and
stapled.

- **The code in an app** is signed the deepest first, so each piece is
  signed after what is in it, the app last: bundles of code (.app, .appex,
  .framework, .xpc, .systemextension, and a .bundle or .plugin with an
  executable) and every Mach-O file, wherever it is, but a bundle's own
  executable, which is signed with its bundle. Mach-O is told by a file's
  first bytes (thin or universal, 32- or 64-bit, either byte order), not
  its name or permissions: libraries, a Mac app's helpers, and a tool it
  bundles in folders of its own (OS Server's QEMU in
  `Contents/Helpers/qemu/bin` and `qemu/lib`, AXe in
  `Contents/Helpers/axe`). Anything else (firmware, scripts, data) is left
  to its bundle's seal, and symbolic links are not followed.
  - On a Mac, each with Developer ID, the hardened runtime and a secure
    timestamp, and with its own entitlements and identifier as its
    signature had them (QEMU keeps its Hypervisor entitlement, `oss` its
    Virtualization one; `qemu-img` its identifier), less debugging, which
    the notary service refuses. The app's identifier is its bundle id,
    and its entitlements are made its profile's when it has one.
  - On an iPhone, the app and each extension with its own profile
    (below); everything else with the app's identity and no entitlements.
  - codesign takes everything in a Mac bundle's `Contents/MacOS`,
    `Helpers`, `Frameworks`, `PlugIns` and `XPCServices`, however deep, for
    code: a script or a data file loose there fails the app's signing
    ("code object is not signed at all", naming it), so an app keeps them
    in `Contents/Resources` (OS Server keeps QEMU's firmware in
    `Contents/Resources/qemu`).

What it needs on that Mac:

- **Identities** in the keychain of the user the service runs as, found
  by kind and team: Apple Development (betas), Apple Distribution
  (production, with ad hoc profiles), Developer ID Application (Mac apps).
  None is named in the repository or printed; `status` says which kinds
  are there. Each one's private key lets codesign use it without asking
  (Keychain Access, the key's Access Control), as the service runs with no
  one at the screen.
- **Profiles** in the data folder's `profiles/`, copied there from the
  team's account. Any file name: each is read for what it says of itself
  (`security cms -D`): its bundle id, its kind (development: devices and
  debugging; ad hoc: devices and no debugging; App Store: no devices, not
  used yet; enterprise; a Mac app's Developer ID), its certificates, its
  entitlements and its expiry. Named for people, say:

      profiles/com.LoganShire.Visor.Beta.mobileprovision            development: Visor β
      profiles/com.LoganShire.Visor.Beta.Widgets.mobileprovision    development: its widgets
      profiles/com.LoganShire.Visor.mobileprovision                 development: Visor, until it has an ad hoc one
      profiles/com.LoganShire.Visor.adhoc.mobileprovision           ad hoc: Visor's releases
      profiles/com.LoganShire.Visor.Mac.provisionprofile            Developer ID: only for entitlements Apple restricts

  - Every iPhone bundle id needs its own, of each app's beta (`<id>.Beta`)
    and production, and each extension's. Wildcard profiles are not used.
  - A beta takes development profiles. Production takes ad hoc ones when
    every bundle in the app has one, so it is signed with one certificate
    throughout; else development ones, as a beta's.
  - A bundle id with no profile that will do refuses the publish, naming
    the bundle id (and, when the one there has expired, when). Nothing
    falls back to another id's profile: a beta's `.Beta` id needs a
    profile of its own, as Xcode's would.
  - A Mac app is signed for its profile's team, else the profiles' (when
    they are all one team's), else the APNs key's.
- **The notary key:** an App Store Connect API key
  (`applications-server notary`), kept as notary.p8 beside the settings,
  its id and issuer in config.json, never printed. Without one, Mac apps
  are signed and not notarized, and the server's log says so.

Codesign, the keychain and notarytool are behind `CodeSigning` and
`Notarizing`: the tests' fakes stand in for them, and a Linux server's
would be rules_applecross's codesign, which signs and notarizes Apple's
code from Linux.

## What is installed

iOS lets no app see another's version; it answers only whether some app
opens a URL scheme, and only for the schemes the asking app lists
(LSApplicationQueriesSchemes, at most 50; iOS refuses the rest, "not
allowed to query"). Since 2026-11-02 (the owner's rule) one bundle id is
one app installed at a time, whichever of its Alpha, Beta, AdHoc and
Production was installed last, and Applications on the iPhone asks two
things of it:

- **Whether it is installed:** the app's own link scheme (`visor://`), one
  an app, which Applications lists (app/Info.ios.plist's
  LSApplicationQueriesSchemes; an app without one can't be asked about, and
  is taken at its word below).
- **Which build:** the app writes its version, build and variant to the
  database it shares with Applications at each launch (ApplicationUpdates,
  docs/Updates.md), overwriting the last; the build installed is the one of
  that variant. An app that opens but has written nothing shows "Unknown
  version installed", and none of its builds is marked installed. One that
  doesn't open is not installed, whatever it wrote before.

So at most one of an app's builds shows as installed. Applications knows
its own version. The build schemes below (`applications-<release>-build-<n>`)
are still numbered and stamped into production builds by the server, but
Applications no longer asks about them; they go once every app records
itself.

- **The release** is Applications': MAJOR.MINOR of its version (0.6.3 is
  0.6's). The
  server's current release is that of the newest Applications production
  iPhone build (`com.LoganShire.Applications`, published by a release) it
  has, by number, so a build of an older one does not take it back (its
  betas set nothing); before the first, the server's own, which is the
  same: Applications and its server have one version, as Visor's app and
  server do (MODULE.bazel's, the apps' Info.plists' and
  `ApplicationsServer.version`; //tests/server_tests holds them together).
- **Numbers belong to one release** and go to other apps' production
  builds in order, 1 to 49, each never again: a phone keeps a build's
  scheme as long as it keeps the build; betas take none, so a release's 49
  last. The pool of 25 this replaced (`releases-build-N`, a
  scheme given out again once a newer build freed it) made Visor 0.41.15
  look installed, because a stale install of the Storybook still carried
  the scheme. 50 is held back: once 49 are given, the server gives no more,
  and refuses releases' builds that need one, until an Applications
  release of a newer MAJOR.MINOR is published, which starts that release's
  1 to 49. Applications' own builds, and betas, are always accepted.
  schemes.json, beside the builds, keeps each release's next number and
  whom each went to (the bundle id and the commit).
- **CI's release job may stamp the scheme in at build time.** Before it
  builds an iPhone app (`--config=prod`), it asks the server for the
  build's scheme by bundle id and commit, and puts it in the app's
  Info.plist as a URL type of its own (`CFBundleURLTypes`, named
  `applications-build`). Asked again for the same app and commit under the
  same release, the server answers the same:

      applications-server scheme <bundle id> --commit <sha>
          # on the server's Mac: the scheme alone, or nothing for Applications or a beta's id
      POST /api/build-scheme  {"bundleID": "<bundle id>", "commit": "<sha>"}
          # elsewhere, with the password (none from the server's own Mac)
          # {"release": "0.6", "scheme": "applications-0.6-build-3"};
          # {"release": "0.6"} for Applications or a beta's id; 409, saying why, once 49 are given

  A release's build that comes with its scheme keeps it as the server
  signs it; one whose scheme was not given to its app here is published
  all the same, and the server's log says so. CI's builds, which the
  server signs anyway (below, "Signing"), need not stamp: one that comes
  without a scheme is given the next number, and its scheme is added as it
  is signed; one that cannot be signed is refused, its number given back.
- **A build of an earlier release** keeps that release's scheme, which a
  newer Applications does not list: it cannot be asked about, so
  Applications goes by what it handed iOS, as for an untagged build, until
  the app's next build. Builds that carry a scheme of an earlier pool
  (`releases-build-N`) are the same.

## Publishing

    applications-server publish path/to/App.ipa --notes-file notes.md     # or --notes "<text>"

On the server's Mac no password is needed (it posts to the loopback); from
another computer that reaches it, add `--code <connection code>`.

A build published so is a beta, whatever its bundle id, published as it
came, signed as its builder signed it. Nothing published by hand is
production: asking for a release (`--release`, or the header
`X-Applications-Release: true` an earlier command sent) is refused, saying
so, and the build is not kept. Production comes from a release's CI alone
(below, and docs/CI.md).

**From CI**, a job publishes with its GitHub Actions OIDC token in place of
the password, over HTTPS, and the token, not a header, decides what the
build is: a releaser's push of a release branch (`release-MAJOR-MINOR`) is
production (a `v*` tag a releaser published, too), anything else from a
configured repository (a branch, a pull request, main) a beta, and a bundle
id not the repository's is refused. A build's `BuildVariant` must match:
Production only from a release branch (docs/VARIANTS.md). The server signs
each build before it publishes it (below, "Signing"). docs/CI.md has the
whole of it, the workflow and tools/ci/publish_from_ci.sh:

    POST /api/publish   Authorization: Bearer <the job's OIDC token>
        # the package as the body; X-Applications-Notes and X-Applications-App (base64), X-Applications-Commit
        # 201 the build; 401 the token refused; 403 the token may not publish it; 400 the package refused

**Versions.** Before it builds, the job asks for its build's version with
the same token and stamps it into the build's Info.plists
(tools/ci/next_version.sh; docs/CI.md, "Versions"): MAJOR.MINOR.BUILD, the
next of the line the repository commits (MAJOR.MINOR.0), for the token's
commit (its `sha`). It is `applications-server next-version` over HTTPS:
the same number for that commit, however often and from whichever job it
is asked.

    POST /api/next-version   Authorization: Bearer <the job's OIDC token>
        # {"app": "<app>", "line": "MAJOR.MINOR"}
        # 200 {"version": "MAJOR.MINOR.BUILD"}; 401 the token refused; 403 its repository not configured here,
        # or the app not one of its bundle ids' (by their builds here, or `applications-server app`); 400 not such a request

The app is the one the server counts the builds under ("Visor", for Visor
β's too). With the password (none from the server's own Mac) the same
request asks for any app, and keeps the version as the commit's when it
names one (`"commit": "<sha>"`), as `next-version --commit` does.

Agents on computers without the code leave builds in the inbox instead: a
draft release tagged `inbox` in a private repository, which the server's
`gh` reads every minute (`applications-server inbox <owner/repo>`):

    gh release upload inbox <name>.ipa <name>.md --repo <owner/repo> --clobber   # or .zip, .dmg, .apk

`<name>.md` is the build's release notes. Builds from the inbox are betas.
A line `<!-- app: <app> -->` in them names the app the build is a build of,
where its own name does not (the server takes the line out of the notes);
`publish --app <app>` does the same from the command line, and
`applications-server app <bundle id> <app>` on the server's Mac counts every
build of a bundle id as the app's. Every build's signature is checked when
it is published (a build the device would refuse is refused), and the "._"
files macOS archivers leave in an .ipa are taken out. The server publishes
the build, pushes it to the devices, and removes both from the inbox.

**Channels.** A build's channel is how it was published: a beta, or
production when a release's CI published it. Nothing is promoted: a
release builds its production build (`--config=prod`) and its CI
publishes it with its token. Production builds are kept however many come after; of the
others, each bundle's newest for good, an Alpha (or a build with no
`BuildVariant`) for a week and a Beta for two weeks. A build's
`BuildVariant` is kept with it (`Build.buildVariant`). `<id>.Beta` and
`<id>` are one app, listed under the production's name (the beta's without
its " β", or as `applications-server app` names either id). A build from
before builds had a channel of their own is its version's, as
channels.json kept it.

### Release notes

What the person installing reads to know what to test. The first line is
the change in a sentence (it is the push's text); then sections:

    Dictation in the composer; attachments open in Quick Look.

    ## What's new
    - The microphone in the composer dictates into the draft.
    - Pictures and videos you attach are tiles that open in Quick Look.

    ## What to test
    - Dictate a message, edit it, send it.
    - Attach a video, open it from the composer and from the sent message.

Bullets, **bold**, `code` and links show as such. Name what changed for the
user, not the commits; say what to try, and anything known not to work yet.
