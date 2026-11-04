# Applications

Distributing builds of the owner's apps, whatever the app: a server that keeps
them, and an app that installs them.

- **Applications Server**: keeps each app's builds by bundle id (every one a
  `com.LoganShire.*` id), with the commit each was built from.
  - It hands them out over the air: an iPhone's install from a manifest
    signed by its own certificate authority, a Mac's .zip, an Android .apk.
  - It tells devices of new builds.
  - A menu bar app, as Visor Server is, and a command line, the Swift
    binary alone, on macOS or Linux.
- **Applications**: the app on the iPhone, iPad and Mac.
  - Every app's builds, one entry an app, by its production bundle id: its
    production builds (its releases') and its betas (a branch's latest,
    main's), apart.
  - It installs them, and knows which production build is installed.
- **ApplicationUpdates**: the Swift package the apps it distributes take
  (Package.swift at the root, by version through rules_swift_package_manager).
  Applications writes each app's newest build to a database they share in
  the app group `group.com.LoganShire.Applications`; each app writes the
  build it is, and tells its user of a newer one itself, with a
  notification whose Install installs it (docs/Updates.md).
- **Alpha and Production** are one app: one bundle id, name and link scheme,
  the build's Info.plist saying which it is (`BuildVariant`). The Alpha is
  the default build, main's and every pull request's; Production is built
  with `--config=prod` by CI's release job alone, on a release branch the
  owner cut (docs/VARIANTS.md). Other apps' betas (`<id>.Beta`) are listed
  with their production.
- **Builds come from CI.** Each repository's CI publishes its commit builds
  and releases here, unsigned, with its GitHub Actions OIDC token in place
  of a password; the server checks it and signs them: CI holds no signing
  key (docs/CI.md). Production comes from a published release's CI
  alone; a build published by hand is always a beta.

**Keeping builds:**
- A branch keeps its latest commit build, which replaces the one before; it
  goes when the branch merges.
- Main's builds stay until a release is tagged.
- Released builds stay for good.

The server runs as a launchd service of its own, on 7461 (HTTPS) and 7460
(plain HTTP, for its certificate authority's profile and little else).

docs/APPLICATIONS_PLAN.md says where it goes from here, and in what order;
docs/SERVER.md how the server and the app work, docs/VARIANTS.md the
beta and production builds, docs/CI.md how CI publishes and the
server signs, and docs/Updates.md how an app learns of its updates.

## Layout

- server: the server's command line (`applications-server`).
- libraries/applications_server: the server itself: publishing, channels,
  push, over-the-air installs.
- libraries/applications_publish: publishing from the command line.
- app: the app (iPhone, iPad, Mac).
- libraries/:
  - pipeline_http: HTTP;
  - pipeline_server: the server's certificate authority and addresses;
  - pipeline_client: the connection code and the pinned client;
  - pipeline_app: an app's connection to its server;
  - pipeline_snapshots;
  - applications_protocol: what server and app say to each other;
  - application_updates: ApplicationUpdates, the apps' updates (the Swift
    package Package.swift makes of it, for other repositories), and its
    tests.
- tests/: the app's screens on the iPhone and iPad (app_tests) and on
  the Mac (mac_tests), and the server's tests (server_tests). The
  protocol's and the client's own tests are beside them, in
  libraries/applications_protocol/tests and libraries/pipeline_client/tests.
- artwork/: the app's icon.
- third_party/, tools/: Bazel's packages, patches and signing,
  tools/install_mac_app.sh, which signs the Mac app and publishes it, and
  CI's scripts (docs/CI.md): tools/ci/container_build.sh, which builds in a
  Linux container, the Mac app CI publishes included;
  tools/ci/check_mac_icons.sh, which checks that app's icon's dark
  appearance on a Mac slot (tools/ci/mac_slot.sh); tools/ci/ios_lease_tests.sh, which runs the iPhone and iPad
  tests on an iOS lease and makes the proof, its screens compared with
  their pictures at its base (tools/ci/proof_baseline: a push's commit
  before); tools/ci/mac_vm_tests.sh, which builds the tests that need a
  Mac on Linux (tools/ci/build_mac_tests.sh) and runs them on a slot of OS
  Server's primary Mac; tools/ci/next_version.sh,
  which stamps a CI job's builds with the version the server gives its
  commit; tools/ci/publish_from_ci.sh, which publishes them with its
  token (both through tools/ci/connect_from_ci.sh). CI's workflow is
  .github/workflows/ci.yml.

## Building

    bazel build //server //app:applications_macos
    bazel build //app:applications_ios --ios_multi_cpus=sim_arm64   # a device build needs your team
    bazel test //tests/... //libraries/...
    swift test        # ApplicationUpdates as a Swift package (Package.swift), on a Mac or Linux

Each builds the Alpha; `--config=prod` builds Production, which CI's
release job alone does (docs/VARIANTS.md).

(`bazel build //app/...` stops on the app's two libraries, one for the
iPhone and one for the Mac, both module `ApplicationsApp` in the host's
configuration: name the targets, which build each in its own.)

Signing needs your Apple team in a `.bazelrc.user` at the root, which is not
checked in: `common --repo_env=PIPELINE_TEAM_ID=<team>` (tools/signing).

### On Linux

The same targets build on Linux, without Xcode, as isomer's and visor's
do: the apps and the server (the Mac's command line, until the server runs
on Linux: docs/APPLICATIONS_PLAN.md) with rules_applecross, from Xcode
27.2's SDK archive, and the libraries and tests that run on Linux, for
Linux. `tools/ci/container_build.sh` builds in the Linux container it runs
in (a CI job's, or a Visor session's), or, run on the Mac, in a container
leased from that Mac's OS Server (0.12.0 or later; containers are lent on
the server's own Mac), of Visor's agent image. The SDK archive and
rules_applecross's ported tools come from OS Server's files, at
OSS_FILES_HOST or the first of OSS_SERVERS:

    tools/ci/container_build.sh                       # what CI runs: the builds below, then the tests
    tools/ci/container_build.sh build //app:applications_ios
    tools/ci/container_build.sh test //libraries/...
    tools/ci/container_build.sh package .ci/packages --config=beta //app:applications_macos   # the .zip copied out (as CI's alpha builds it: docs/CI.md)

With no arguments it builds `//server`, `//app:applications_ios`,
`//app:applications_macos` and `//libraries/...`, then runs `bazel test
//...`: under two minutes from cold. Off a Mac an iPhone app is the
arm64 simulator's and a Mac app arm64 (`--ios_multi_cpus=arm64` for a
device's). Libraries that need Apple's frameworks (pipeline_http,
pipeline_server, applications_server, applications_publish) are passed over
by `//libraries/...` there, and built for the Mac in `//server`. Linux runs
the protocol's and the client's tests; the app's, the Mac's and the
server's are skipped, as they need a Mac: a simulator, AppKit, and the
server's Network, Security, CryptoKit and Mac tools (hdiutil, ditto, sips,
codesign).

The script writes `.ci/downloader.cfg` (not checked in), which points
MODULE.bazel's placeholders at the server's files, whose read token the
lease puts in the container's `.netrc`. Another Linux builder in this
checkout (a Visor session's container) turns the same on in its
`.bazelrc.user`:

    build:linux --config=apple_on_linux
    common:linux --downloader_config=%workspace%/.ci/downloader.cfg

A device build of the iPhone app with the team's profile is a Mac's: a
container hasn't got the profile. CI's is `--config=ci_device`, signed ad
hoc with a placeholder profile, which Applications Server signs again when
it is published (docs/CI.md, "The iPhone app").
