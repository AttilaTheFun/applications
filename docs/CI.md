# CI: builds published and signed by Applications Server

2026-10-28: Applications Server signs every build. CI never holds a
signing key, a notary key or the server's password: a job builds its apps
unsigned and sends them to the server with its GitHub Actions OIDC token,
which says where they came from. The server checks the token, decides what
the job may publish and as what, signs the builds with its own identities
and profiles, and publishes them.

## A release is a release branch

2026-11-01: a release is a branch, `release-MAJOR-MINOR`, cut by the owner
at a main commit.

1. An agent runs CI by hand (`workflow_dispatch`) on a main commit, which
   makes its proof. No release without its commit's proof.
2. The owner looks at the proof and cuts the release branch at that
   commit.
3. The push starts the repository's release job, which checks the branch's
   commit is main's and, building nothing, has the server promote main's
   Alphas of that commit with its token: the builds the owner tested,
   stamped Production (the same bundle id, its Info.plist's `BuildVariant`
   "Production", docs/VARIANTS.md) and signed again ("Production by
   promotion", below). The token's ref, `refs/heads/release-*`, pushed by a
   releaser, is what the server takes as a release. Nothing else makes a build production, and the
   server asks nobody else first: the token is the approval.

There are no GitHub environments: a private repository on the owner's
plan can't protect one with a required reviewer, so the approval is the
owner's cutting the branch.

## What a job may publish

The server takes a token signed by GitHub (RS256, by a key in GitHub's
JWKS, which it fetches and caches, and fetches again for a key it does not
have, at most once a minute), issued by
`https://token.actions.githubusercontent.com`, for its audience
(`applications-server` unless set), and current (`exp`, `nbf`, `iat`, a
minute's leeway). From its claims (`repository`, `ref`, `ref_type`, `sha`,
`event_name`, `actor`, `run_id`, `workflow_ref`) it decides
(libraries/applications_server/Sources/CIPolicy.swift):

| The token | The build |
| --- | --- |
| a repository not configured here | refused (403) |
| a bundle id not its repository's: another repository's, or none's | refused (403) |
| a release branch, `release-MAJOR-MINOR`, pushed by a releaser | production, signed with the production identity; its build's `BuildVariant` must be `Production` |
| a `v*` tag, released (`release`) or pushed (`push`) by a releaser (before release branches) | production, signed with the production identity; a beta's bundle id (`<id>.Beta`) refused |
| a `v*` tag anyone else released or pushed, any other tag, or a tag's run of another event | refused (403), not made a beta |
| anything else: a branch, a pull request, main, a run started by hand | a beta, signed with the development identity, whatever its bundle id; a `BuildVariant` of `Production` refused |

A repository is known by its name and, from its first token here, by its
number at GitHub too (`repository_id`), which the server pins and keeps
(config.json's `repositoryIDs`). A name is GitHub's to give again (the
repository renamed or deleted, its owner's name taken), a number never: a
token whose repository has the name but another number publishes nothing
and is given no version (403). If the repository really was made again,
`applications-server repo <owner/repo> <bundle id>…` on the server's Mac
lets go of the old number, and the next token pins the new one.
`applications-server status` says each repository's number, or that it
is not pinned yet.

A tag is a release's or nothing. A tag's build is a production build
(`--config=prod`); one that a releaser did not release is refused, so its
job fails where it can be seen, rather than published under the
production bundle id as a beta nobody approved.

A production bundle id in a beta is fine, and since 2026-11-01 it is the
only one Applications has: its Alpha, every main commit's, has the
production id, and the server takes it as a beta because of its token's
ref, not its id (docs/VARIANTS.md). Its `BuildVariant` holds the two
apart the other way: a Production build is published only from its
release branch, and a release branch publishes only Production builds.

A beta's commit is the one the job says it built (`X-Applications-Commit`:
a pull request's head, which its token does not name), else the token's;
its branch and pull request are the token's. A release's commit is the
tag's, as its token says.

**Not checked yet:** that a release's tag is on main. The token does not
say, and the server has no GitHub access of its own to ask (only the `gh`
the inbox uses, where it is signed in). The release job checks it before
it builds (`git merge-base --is-ancestor HEAD
origin/main`). That check is the workflow's, though, and a tag's own
workflow could leave it out. TODO: the server asks GitHub
(`repos/<repo>/compare/main...<sha>`, behind or identical) once it has a
token of its own.

## What the server does with each build

- **iPhone (.ipa):** the app and all the code in it, inside out:
  frameworks, libraries and any other Mach-O file with the app's identity;
  the app and each extension with the profile for its own bundle id,
  copied in as `embedded.mobileprovision`, and its own entitlements as it
  was built, made the profile's (its application identifier, team and
  keychain groups, the profile's push environment and debugging). One
  that asks for an entitlement its profile does not allow is refused, as
  iOS would refuse it.
  - A beta: the development identity and development profiles.
  - Production: the same, unless every bundle in the app has an ad hoc
    profile, when it is those and the distribution identity. Installs are
    over the air to the owner's devices for now; the App Store's profiles
    come with TestFlight. Its build scheme is given as it is signed
    (docs/SERVER.md, "What is installed"), unless CI stamped one.
- **Mac (.zip, .dmg):** Developer ID Application, the hardened runtime and
  a secure timestamp, on every Mach-O file and bundle of code in it, the
  deepest first, each with its own entitlements and identifier
  (docs/SERVER.md, "Signing"), then notarized with notarytool and the App
  Store Connect key the server keeps, stapled, and zipped again.
  Betas too, so Gatekeeper takes them however they arrive. Notarizing
  takes a few minutes, which the publish waits for (the script allows an
  hour); if it turns out too slow for every commit, betas could skip it.
- **Android (.apk):** published as it came, as before: the server signs no
  Android app yet, and refuses one without a signature of APK Signature
  Scheme v2 or later, saying so.

The server's Mac needs the identities and profiles (docs/SERVER.md,
"Signing").

## The workflow

This repository's is `.github/workflows/ci.yml`, the CI pilot
(2026-10-28). Every job runs on OS Server's single-use self-hosted runners
(label `applications-jit`, since 2026-11-04; before that, all but
`mac-tests` ran on a runner of the owner's Mac, as a hidden user of its
own): a new Linux container for each job, of Visor's agent image (Bazel,
Swift, Python, unzip), its CPUs and memory OS Server's `ci.sizes` for this
repository, with:

- `oss` on its PATH, with the job's grant to lease and use what it needs:
  a slot of OS Server's primary Mac (`mac`), an iOS simulator (`ios`);
- in its ~/.bazelrc, OS Server's Bazel cache (read-only), and in its
  ~/.netrc the cache's read token, which opens OS Server's files too;
- in OSS_SERVERS, OS Server's addresses, the first of them the host
  Bazel's downloader config names (tools/ci/oss_files.sh).

Each job builds in its own container, leases what needs a Mac and gives it
back however it ends:

| Job | Runs for | What it does |
| --- | --- | --- |
| `linux` | pull requests, main | `tools/ci/container_build.sh`: every target built in the job's container (the apps and the server with rules_applecross), then the tests Linux runs. `alpha` and `release` build the Mac app they publish the same way (below: "The published Mac apps are built on Linux") |
| `mac-tests` | main, by hand | `tools/ci/mac_vm_tests.sh`: the tests that need a Mac, built on Linux in the job's container and run on a slot of OS Server's primary Mac (below) |
| `ios-tests` | pull requests, main, by hand | `tools/ci/ios_lease_tests.sh`: the iPhone and iPad tests built on Linux and run on an iOS lease (`oss machine xctest`); by hand alone, then the proof from their result bundle (below: "Tests on an iOS lease") |
| `alpha` | main, after `linux` | the Alpha (`--config=alpha`): the version stamped in (tools/ci/next_version.sh, below: "Versions"), the Mac app and the iPhone and iPad app built with `--config=alpha` in the job's container (`tools/ci/container_build.sh package`; the iPhone's a device build signed ad hoc, below: "The iPhone app"), the Mac's icon checked for the dark appearance on a Mac slot (`tools/ci/check_mac_icons.sh`), and both published with tools/ci/publish_from_ci.sh: a beta, which the server signs (the Mac's with Developer ID, notarized; the iPhone's with the development identity and profiles) |
| `adhoc` | by hand (`workflow_dispatch`) on a branch that is neither main nor a release branch | the same with `--config=adhoc`: an AdHoc build, which the server keeps a week (docs/VARIANTS.md) |
| `release` | a push to a `release-*` branch | nothing built: once the branch's commit is found on main, `tools/ci/promote_from_ci.sh` has the server promote main's Alphas of it to production |

A pull request's run is `linux` and `ios-tests`: the apps, the server and
the tests built on Linux, the tests Linux runs, and the iPhone and iPad
tests on an iOS lease, in under ten minutes. The Alpha and the tests that
need a Mac are main's, per commit, and the proof is by hand alone
(2026-11-01, for CI's time: run to propose a release, or after the fact to
bisect a regression). Before that (the owner, 2026-10-31: "Beta
builds and proof should be per master commit not PR commit. The CI that
runs per pr commit and must pass should ideally consist of building the
apps and tests on linux and then running relatively fast test suites.").
A job's container is new each run: its builds start from OS Server's Bazel
cache, not a tree of their own. (On the owner's Mac's runner, each job kept
its tree in a volume of its own, applications-ci-linux, -ios, -alpha and
-adhoc, which went with it.)

- **Which commit.** A pull request's jobs check out its head, not GitHub's
  merge of it: the commit its builds and its proof are listed under.
- **Cancelling.** A pull request's newer push cancels its older run; main's
  and a release's runs finish.
- **Forks.** A fork's pull request runs nothing: a self-hosted runner never
  runs a fork's code, and a fork's run gets no token.
- **The token.** Only `alpha` and `release` have `id-token: write`, which is
  what lets a job ask for a token: its builds' version, then their publish.
- **Untrusted text** (a pull request's title, a release's body) reaches the
  shell through `env`, never `${{ }}` inside `run`.
- **Leases.** A step that leases execs its script, so the runner's cancel
  reaches it, and the script's trap releases the slot or the simulator on
  every path. A job killed outright leaves its lease until it runs out.
- **What needs a Mac** goes to a slot of OS Server's primary Mac
  (tools/ci/mac_slot.sh: `oss machine lease mac`, then `upload`, `exec`
  and `download`): Xcode's `assetutil` and `xcresulttool`, and the proof's
  CoreGraphics diffs.
- **Builds come out of Bazel's tree** through `container_build.sh package
  <dir> <bazel args…>`: the targets' files (by `bazel cquery
  --output=files`) copied into `<dir>` in the checkout.
- **By hand from a Mac**, container_build.sh leases a container from that
  Mac's OS Server instead (its checkout mounted, which only the server's
  own Mac may), the build its main process (`--command`): a script it
  writes into .ci/container, which runs the build there and writes its log
  and exit status beside it, which the script follows, passing the status
  on and releasing the container. The cache's read token reaches the
  container's .netrc through a file there, never a command line. It needs
  OSS_FILES_HOST (or OSS_SERVERS): the name the container reaches OS
  Server's files by.
- **macOS's bash is 3.2.** It reads a byte of "…" after `$name` as part of
  the name, so the scripts write `${name}…`. When an unset variable stops a
  script under `set -eu`, it runs the EXIT trap with `$?` 0 and ends with
  0, so each script counts an end before its last line as a failure. That
  is what hid main's first publish: the job passed and nothing was sent.

Another repository copies `alpha` and `release`, with
tools/ci/container_build.sh and the oss_files.sh it sources,
tools/ci/check_mac_icons.sh and the mac_slot.sh it sources,
tools/ci/next_version.sh, tools/ci/publish_from_ci.sh and the
connect_from_ci.sh both source, and names its own app, Info.plists and
targets.

### The published Mac apps are built on Linux

2026-10-28: every app with an Icon Composer icon follows dark mode
and tinting. rules_applecross's actool compiles an `.icon` document's
layers and appearances (Aqua, DarkAqua, Tintable; its icon groups) as
Xcode does since its 0.0.3.3251084 (its #242), and `.bazelrc`'s
`apple_on_linux` accepts the icon's flattened images, which aren't Xcode's
(`RULES_APPLECROSS_RELAX_ACTOOL_ICON_COMPOSER`; macOS 26 and later draw
the icon from its layers). Until then it compiled one flat image, and
`alpha` and `release` built the app they publish in a macOS VM.

Now they build it in the job's Linux container (`tools/ci/container_build.sh
package .ci/packages …`, which builds the checkout as the Version step
stamped it), and `tools/ci/check_mac_icons.sh .ci/packages` checks each
Mac app's icon: it unzips the app, runs `xcrun assetutil --info` on its
Assets.car on a Mac slot, and fails if it has no
`NSAppearanceNameDarkAqua` rendition (or no Assets.car). So a flat icon is
never published: the job fails before its Publish step. `alpha` holds the
token (`id-token: write`) and waits for `linux`.

### The iPhone app

`alpha` and `release` build the iPhone and iPad app beside the Mac's, in the
same container, as a device build (`--config=ci_device`, .bazelrc:
`--ios_multi_cpus=arm64 --ios_signing_cert_name=-`). rules_apple wants a
provisioning profile for a device build, and CI holds none of the team's,
so app/BUILD.bazel gives that build a placeholder
(`:ci_placeholder_profile`, its team the build's `TEAM_ID`), which allows
what app.entitlements asks for, and the app is signed ad hoc. The server
replaces both with the bundle id's own profile and the team's identity
(above: "What the server does with each build"). The placeholder is a
plain plist, which rules_applecross's `security cms -D` reads off a Mac:
`--config=ci_device` is for Linux, and a Mac's device build keeps the
team's profile (`:app_profile`).

### Which runs make a proof

2026-10-30, for every repository: pull requests build and run the
tests, the snapshot tests compared with the kept pictures, and make no proof
and record no pictures. Since 2026-11-01 a push to main makes none either:
only `workflow_dispatch` makes the proof, against the release before the
commit, to propose a release, or on a branch pushed at an earlier commit
to bisect a regression. A release's proof is its main commit's, which the
owner reviews before publishing it. The scripts make the proof only with
`--proof`, which CI passes for dispatches alone.

### Tests on an iOS lease

`tools/ci/ios_lease_tests.sh [--proof <dir>] [--logs <dir>] [--kind quick|full]`
builds //tests/app_tests and its host in the job's container
(`container_build.sh package`, with `--//tools/ci:ios_tests_anywhere`, which
lets an iOS test build off a Mac), leases an iOS simulator (an iPhone 17, as
`.bazelrc`'s tests run on), and runs it with `oss machine xctest`, keeping
its JUnit and result bundle. A lease's run takes no environment, so the
proof's pictures are the ones the snapshot library attaches to the results
(every picture, kept whether the test passes or not), exported with
`xcresulttool export attachments` on a Mac slot. Then, with `--proof`, the
proof is made: each picture against the one kept at the base (`git show
<base>:tests/app_tests/Snapshots/<name>.png`), by
tools/ci/snapshot_diff.swift (CoreGraphics), built and run on the slot,
from tools/ci/proof_baseline's base, built by the job's swiftc. It replaced the macOS VM's recording on 2026-10-30, when
both made the same proof of main (375f9fa: 7 screens, byte for byte).

By hand, the job uploads the proof as the artifact `proof`
(kept 90 days), whether the tests pass or not, and the runs' JUnit and
result bundles as `ios-test-logs`. It fails as the tests do, or where the
base can't be fetched or no picture came back. The proof:

    screens/<name>.png   every picture the app's tests take
    before/<name>.png    each that differs from its picture at the base, as the base kept it
                         (tests/app_tests/Snapshots there); none for a screen the base hasn't got
                         (new, and changed)
    diffs/<name>.png     each that differs: the new picture faded to grey, the pixels that differ
                         red (kept beside before/ for now)
    proof.json

```json
{
  "commit": "<main's commit>",
  "ref": "refs/heads/<branch>",
  "kind": "full",
  "run": 18923456789,
  "base": {"ref": "main", "commit": "<main's commit as the run fetched it>"},
  "screens": [
    {"name": "pad-app", "changed": false, "changedPixels": 0},
    {"name": "phone-list", "changed": true, "changedPixels": 6120}
  ]
}
```

- The base is what the screens are compared with (tools/ci/proof_baseline,
  whose choice //tools/ci/proof_baseline:baseline_tests tests, in `linux`'s
  `bazel test //...`): a pull request's base branch as it is
  (`GITHUB_BASE_REF`), a push's commit before it, a release's release
  before it (the highest version tag below its own); CI's run by hand
  (`workflow_dispatch`, the proof's only run), the release before the
  commit (the highest `v*` tag in its history before it), else the commit
  before; by hand outside CI, main (a checkout that isn't shallow is
  fetched into without `--depth`). Never
  this tree's kept pictures: a pull request re-records those, and would
  show each screen it changed as unchanged. The tests still compare with
  this tree's kept pictures, so a pull request that re-records them is
  green, and its proof shows what it changed from main.
- `kind` is "full" for a run by hand (the only one that makes a proof). Both run
  the same set.
- A pixel differs when a channel is more than 24 apart, as the snapshot
  tests count them, so text drawn a hair differently doesn't count.
- Pictures of different sizes are compared from the top left. A screen the
  base has no picture of differs everywhere.
- `run` is the workflow run's id.

The job's summary lists the screens and their changed pixels against the base.

### Tests on a Mac slot

`tools/ci/mac_vm_tests.sh [--logs <dir>]`, in the job's own Linux container
(applications-jit):

1. Builds the tests that need a Mac (`macos_unit_test` under //tests and
   //libraries: the server's, the Mac app's window, the libraries' Apple
   side) for an Apple silicon Mac, with
   rules_applecross (`tools/ci/build_mac_tests.sh`,
   `--//tools/ci:mac_tests_anywhere`): each an .xctest bundle, whole, its
   files in its Resources. Bazel reads OS Server's cache and fetches the SDK
   archive and the ported tools from its files.
2. Leases a slot of OS Server's primary Mac (`oss machine lease mac`: a
   macOS user of its own on a VM that stays up), and releases it on every
   exit (a trap).
3. Runs each bundle there, a bundle at a time (`oss machine xctest`,
   stopped after 15 minutes), and takes its output and JUnit, uploaded as
   `test-logs` when it fails. The server's tests run as the slot's user
   (disk images mount with hdiutil there); the Mac app's window tests in
   the primary's GUI session (`--gui`). A test that listens takes a port
   the system chooses: runs share the primary's loopback.

The Mac's pictures aren't compared there: they compare only where `CI` or
`SNAPSHOT_COMPARE=1` is set, which nothing passes into the tests. The tests
with nothing of Apple's in them run on Linux (`linux`).

## Versions

A version is MAJOR.MINOR.BUILD. A repository commits MAJOR.MINOR.0 (its
Info.plists' CFBundleShortVersionString; CFBundleVersion is 1), and CI
stamps each build with its own before building it: the next BUILD of that
line, from Applications Server, the same for every build of one commit.
The job asks with the token it publishes with:

    POST /api/next-version   Authorization: Bearer <the job's OIDC token>, over HTTPS
        {"app": "<app>", "line": "MAJOR.MINOR"}
        # 200 {"version": "MAJOR.MINOR.BUILD"}; 401 the token refused; 403 its repository not
        # configured here, or the app not one of its bundle ids'; 400 not such a request

- **The commit is the token's** (`sha`), not one the job names. Its first
  question gives it the next number, kept as that commit's; every later
  one, from any job or re-run, is answered the same.
  - A pull request's token names GitHub's merge commit (the run's
    `GITHUB_SHA`), which its jobs and re-runs share; a new push makes a
    new one. The build is still published under the head
    (`X-Applications-Commit`).
  - A release's is its release branch's commit, a main commit, so the
    release is given the version main's Alpha of that commit was: that
    build, as Production.
- **The app** must be one of the repository's: an app the builds of one of
  its bundle ids (`applications-server repo`; their betas' too) are counted
  under, by their builds here or by `applications-server app <bundle id>
  <app>`. A repository whose app has no build here yet names it so once.
  Whatever its ref: a tag that no releaser made is given a number too,
  though its build is then refused.
- **BUILD** is one past the line's highest: of the app's builds here (a
  pull request's too) and of the numbers given. This is the command line's
  `applications-server next-version <app> <line> --commit <sha>`, on the
  server's Mac. A number given to a build that never came is not given
  again, so versions may skip.
- **By hand**, the same request asks with the password (none from the
  server's own Mac), for any app, with `"commit": "<sha>"` to keep the
  version as that commit's.

### tools/ci/next_version.sh

    tools/ci/next_version.sh <app> <Info.plist>…

Shell (bash, curl, openssl), for any repository to copy with
connect_from_ci.sh. In a job with `id-token: write` and
`APPLICATIONS_CI_CODE`, before the build:

1. reads the line, MAJOR.MINOR, from the first Info.plist's
   CFBundleShortVersionString;
2. takes the job's token and the server as publish_from_ci.sh does
   (connect_from_ci.sh) and asks for `<app>`'s next version of the line;
3. writes it into every Info.plist's CFBundleShortVersionString, in the
   checkout, leaving CFBundleVersion at 1. The Info.plists are XML, as
   committed; the stamp is never committed (each job checks out afresh).

This repository's `alpha` and `release` run
`tools/ci/next_version.sh Applications app/Info.mac.plist app/Info.ios.plist`,
so Applications' builds are 0.10.N. ios-tests doesn't: the proof is not
versioned.

A server from before the route answers 404, or 401 "The password is
wrong" with its password on (it reads a bearer on any path but publish's
as its password): the script warns (`::warning::`) and the builds keep the
committed version, until the server is updated. Any other refusal fails
the job.

## tools/ci/publish_from_ci.sh

    tools/ci/publish_from_ci.sh [--notes-file <notes.md>] [--app <app>] <package>…

Shell (bash, curl, openssl), for any repository to copy with
tools/ci/connect_from_ci.sh, which it sources for steps 1 and 2 (as
next_version.sh does). It:

1. asks GitHub for the job's token (`ACTIONS_ID_TOKEN_REQUEST_URL` and
   `ACTIONS_ID_TOKEN_REQUEST_TOKEN`, with `&audience=`, from
   `APPLICATIONS_AUDIENCE` or `applications-server`), keeps it out of
   command lines and masks it in the log;
2. reads `APPLICATIONS_CI_CODE` (`applications-server code --ci`, a
   repository secret: the server's addresses and the fingerprint of its
   certificate authority, no password), takes the first address that
   answers, and the authority the server presents there (the last of its
   chain), held to the fingerprint; curl trusts that authority alone from
   then on;
3. posts each package to `https://<address>/api/publish` with
   `Authorization: Bearer <token>`, its notes and app (base64,
   `X-Applications-Notes`, `X-Applications-App`) and its commit
   (`X-Applications-Commit`: `APPLICATIONS_COMMIT`, else `GITHUB_SHA`),
   and says what each was published as, or why it was refused.

The server answers 201 with the build; 401 when it refuses the token; 403
when the token may not publish the build (its repository, its bundle id,
its tag); 400 when the package is refused (a profile missing, a signature
that does not verify).

## Production by promotion: tools/ci/promote_from_ci.sh

2026-11-02, the owner: "the alpha builds and production builds should be
identical today modulo the plist key. I test an alpha build and when I'm
happy with it we promote it to a release which stamps it."

    tools/ci/promote_from_ci.sh [--notes-file <notes.md>] [--dmg-dir <dir>]

    POST /api/promote    Authorization: Bearer <the release job's OIDC token>, over HTTPS
                         X-Applications-Notes (base64): the release's notes.

A release's job builds nothing: with its token (connect_from_ci.sh, as
publish_from_ci.sh has it), it asks the server to promote the Alphas main's
CI published of the release's commit. For each (the newest of each bundle
id and platform, among the token's repository's), the server:

1. copies its package, and sets its app's Info.plist `BuildVariant` to
   `Production` (a Mac app's stapled ticket taken out with it);
2. signs it again as a release's build is: an iPhone app with the
   production identity and its scheme given, a Mac app with Developer ID,
   notarized and stapled;
3. keeps it as production, of the same version, beside the Alpha, which
   stays as it was;
4. for a Mac app, makes a disk image of the production app too (the app
   and a link to /Applications, signed with Developer ID, notarized and
   stapled), kept beside it as app.dmg, which downloads by the build's key
   like its package: `GET /builds/<id>/<downloadKey>/app.dmg`.
   `promote_from_ci.sh --dmg-dir <dir>` saves each there as
   `<Name>-<version>.dmg`, for the release job to hand out with its
   release. It is the build the owner tested, not a rebuild.

The token must be a release's (CIPolicy, above): a release branch's push,
or a `v*` tag's, by a releaser. The server answers 201 with the production
builds (asked again, the same ones: nothing is promoted twice); 401 when
it refuses the token; 403 when the token is not a release's; 404 when it
keeps no Alpha of the commit. An Alpha that is not its app's newest is
kept a week, so a release is cut within a week of its commit, or its
commit is the app's newest.

Not promoted: an Android app's Alpha. The server does not sign Android
apps, so it cannot stamp one; an Android release still builds.

## Setting up a repository

On the server's Mac:

    applications-server repo AttilaTheFun/<repo> com.LoganShire.<App>                              # the app's one id (an older app's .Mac and .Beta ids go with theirs)
    applications-server releaser AttilaTheFun                                                     # once, for every repository
    applications-server code --ci                                                                  # the repository's APPLICATIONS_CI_CODE secret
    applications-server app com.LoganShire.<App> <App>                                             # if no build of its app is here yet: the app next_version.sh asks for

Then the profiles for its bundle id, the iPhone's and the Mac's, in the
server's profiles folder (docs/SERVER.md, "Signing"), and the workflow
above in the repository.

## Not yet

- **The on-main check** for a release's commit, on the server (above): the
  release job checks it, the server doesn't yet.
- **The release job is untested.** It runs only for a release branch the
  owner pushes, and none has been pushed since it was switched to
  promotion. Its first run is the test: the on-main check, the server
  taking the release branch's token as a release, and its promoting the
  commit's iPhone and Mac Alphas (signed again, the Mac's notarized).
- **The Mac's pictures in CI.** mac-tests runs the Mac's tests without
  comparing their pictures (a VM draws the sidebar blank). A runner on a
  real Mac's login session, or a VM that draws it, would compare them.
- **A warm Bazel.** Every job's Bazel starts cold but for what OS Server's
  cache has: nothing writes this repository's builds to it yet. A job on
  main with the cache's write token would.
- **Signing on Linux:** codesign and notarytool are behind `CodeSigning`
  and `Notarizing`; a Linux server would wire in rules_applecross's
  codesign (it signs and notarizes Apple's code from Linux), and Security's
  RS256 check would be swift-crypto's.
- **Android signing:** the server keeps no Android key; an .apk is
  published as signed by its build.
