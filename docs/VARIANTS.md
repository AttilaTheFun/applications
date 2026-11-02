# Alpha, Beta, Production and AdHoc builds

2026-11-01 (the owner's layout): an app has one bundle id, its name and its
link scheme on every device and in every build. Which build it is, the
build says in its Info.plist's `BuildVariant`:

|  | Alpha | Beta | Production | AdHoc |
| --- | --- | --- | --- | --- |
| `BuildVariant` | `Alpha` | `Beta` | `Production` | `AdHoc` |
| Built | by default (`--config=alpha`): every main and pull request build, and every agent's | `--config=beta`: TestFlight's, for later (unused for now) | by CI's release job alone (`--config=prod`), on a release branch the owner cut at a main commit | by CI's adhoc job (`--config=adhoc`), when a pull request's branch is run by hand (`workflow_dispatch`) |
| Published | by CI with its token, main's commits (by hand, `applications-server publish`) | — | by CI's release job with its token, alone | by CI's adhoc job with its token, from a branch that is neither main nor a release branch |
| Signed, CI's | by the server: the development identity and profile | — | by the server: the production identity, ad hoc profiles where it has them | as an Alpha |
| On Applications Server | a beta: no build scheme, never numbered; each bundle's newest kept, the rest for a week | kept two weeks (each bundle's newest for good) | its build scheme on an iPhone; kept for good | kept a week, the newest too |
| In Applications | the app's row, its latest; the top of its page | the top of its page | the top of its page | its page's every build, not the top |

The bundle id, the name under the icon and the link scheme are the same for
all four, so they don't install side by side: a build replaces the one
installed.

The server decides a build's kind by how it was published, not by its
bundle id: CI's by its token (a releaser's push of a release branch,
`refs/heads/release-MAJOR-MINOR`, is production; anything else a beta), and
a build published by hand is a beta; asking for a release by hand is
refused. Its `BuildVariant` must agree: a Production build only from a
release branch, and only Production from one; an AdHoc build only from a
branch run by hand that is neither main nor a release branch. Only production builds use
build schemes, so a release's 49 numbers last (docs/SERVER.md, "What is
installed").

Other apps still have betas of their own (`<id>.Beta`, "<App> β") until they
take up this layout; Applications lists them with their production
(docs/SERVER.md).

## The config

`.bazelrc` names the four, Alpha the default:

    build:alpha --//tools/variant:variant=alpha
    build:beta --//tools/variant:variant=beta
    build:prod --//tools/variant:variant=production
    build:adhoc --//tools/variant:variant=adhoc

`tools/variant` holds the build setting and what reads it:

- `BUILD.bazel`: `variant`, a `string_flag` (`alpha`, `beta`,
  `production` or `adhoc`; `alpha` by default).
- `defs.bzl`: `variant_infoplist(name, display_name, url_scheme)`, an
  Info.plist fragment with `BuildVariant` ("Alpha", "Beta", "Production"
  or "AdHoc"), `CFBundleDisplayName` and `CFBundleName` (`display_name`)
  and, with `url_scheme`, `CFBundleURLTypes` (`url_scheme`, named for the
  app's bundle id).

Applications (app/BUILD.bazel) has one bundle id for the iPhone, the iPad
and the Mac:

    BUNDLE_ID = "com.LoganShire.Applications"

    variant_infoplist(
        name = "variant_plist",
        display_name = "Applications",
        url_scheme = "applications",
    )

    ios_application(
        bundle_id = BUNDLE_ID,
        infoplists = ["Info.ios.plist", ":variant_plist"],
        ...
    )

Every build is `com.LoganShire.Applications`, "Applications",
`applications://`, its `BuildVariant` the config's. Its entitlements ask for
the app group `group.com.LoganShire.Applications` (app.entitlements,
app.mac.entitlements), which the bundle id's profiles grant.

The builds share Bazel's output paths: a build of one replaces another's
app there, and only what differs (the Info.plist) is made again. Take a
build's package before building another.

## In another repository

1. Copy `tools/variant/` (it needs `bazel_skylib`) and the three `.bazelrc`
   lines.
2. In each app's BUILD file, the app's one `bundle_id` and a
   `variant_infoplist` in its `infoplists`. Take `CFBundleDisplayName`,
   `CFBundleName` and `CFBundleURLTypes` out of its own Info.plist:
   rules_apple refuses a key that two of an app's plists give differently.
3. Name the bundle id in entitlements as `$(CFBundleIdentifier)`
   (`$(AppIdentifierPrefix)$(CFBundleIdentifier)` for a keychain access
   group), which rules_apple fills in. The team needs an App ID and a
   profile for the one id, with the app's capabilities (push notifications,
   an app group).
4. Code that needs to know which build it is reads `BuildVariant` from
   `Bundle.main`'s Info.plist.
5. An Android app takes the same id as its `applicationId`, and the variant
   where its manifest's values are set.

## In CI

CI builds unsigned and publishes with its OIDC token, which decides what
each build is; the server signs it (docs/CI.md).

- **Main's builds** are the Alpha (`--config=alpha`), published by
  tools/ci/publish_from_ci.sh: betas to the server, signed with the
  development identity and the bundle id's development profile. They ask
  for no build scheme. A pull request's run builds and tests; it publishes
  nothing.
- **The release job**, on a push to a `release-MAJOR-MINOR` branch the
  owner cut at a main commit, builds with `--config=prod` and publishes the
  same way: production, signed with the production identity, its scheme
  given on an iPhone as the server signs it.
- **The adhoc job**, when a pull request's branch (neither main nor a
  release branch) is run by hand (`workflow_dispatch`), builds with
  `--config=adhoc` and publishes the same way: an AdHoc build, signed as an
  Alpha, kept a week. A pull request's own runs publish nothing.
- **By hand**, with the password: `applications-server publish <package>
  --commit <sha> [--branch <name>] [--pull-request <n>]`, always a beta.
  `--release` (or the header `X-Applications-Release: true`) is refused:
  production is a release's CI's alone.

Applications follows the same rules for its own builds: its Alpha has no
scheme and sets nothing; its production release sets the server's current
scheme release (docs/SERVER.md, "What is installed").
