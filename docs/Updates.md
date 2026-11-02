# Updates: ApplicationUpdates

Every app Applications distributes tells its user of its own updates, with
nothing between it and Applications but a database they share. The
owner's design (2026-10-31): Applications and the apps it distributes are in one
app group, `group.com.LoganShire.Applications`; Applications writes each
app's newest build to a SQLite database in the group's container as it
syncs with Applications Server, and each app writes the build it is. At
launch an app looks at its own row, and when the newest build is newer than
itself it shows a local notification, while it is in the foreground, whose
Install installs the update. No build is stamped for it and no URL scheme
is asked about.

The library is `ApplicationUpdates` (libraries/application_updates), a
Swift package at this repository's root (Package.swift) for the other
repositories, and a `swift_library` for this one's Bazel build. It depends
on swift_sql's `SwiftSQL`.

## The database

`ApplicationUpdates.sqlite` in the group's container (`AppGroupStore`):

    apps(bundle_id TEXT PRIMARY KEY, latest_version, latest_build, install_url,
         installed_version, installed_build, updated_at, installed_variant)
    requests(bundle_id TEXT PRIMARY KEY, version, build, requested_by, requested_at)

- **A row an app, by bundle id.** A beta (`<id>.Beta`) is a row of its own,
  as it is an app of its own; so is Applications, beta and production.
- **Applications writes `latest_*` and `install_url`** after each sync
  (app/Sources/Shared/UpdateFeed.swift): each bundle's newest build on this
  device (a production id's production builds before a beta published under
  it; no pull request's), and where it installs from: on an iPhone or an
  iPad its over-the-air install link (`itms-services://…`, the manifest on
  the server's address that answered), on a Mac its .zip. A row is written
  only where something moved.
- **Each app writes `installed_*`** of itself at launch, when it differs:
  its version, build and variant (its Info.plist's `BuildVariant`: Alpha,
  Beta, AdHoc, Production; migration 2). One bundle id is one app installed
  at a time, so whichever was launched last is the row's, even another
  variant of the same version. An app built with the library before the
  variant was recorded writes its version and leaves the variant the last
  one written. Applications writes its own too.
- **`requests`** are a Mac app's asking Applications to install its update
  (below): one a bundle id, taken once by whichever Applications looks.
- **Several processes at once.** Write-ahead-log mode, so one reads while
  another writes; a five-second busy timeout for another's write; and a
  connection opened for each call and closed after it, so no lock on a file
  in the shared container is held while an iPhone app is suspended (iOS
  ends an app for that: 0xdead10cc).
- **Migrations** are numbered (`StoreSchema`, SQLite's `user_version`),
  run in a transaction that takes the write lock first, so of two
  processes opening a new database one makes the tables. They only add: an
  app built before a migration reads and writes a database that has it.
- **A change is announced** with a Darwin notification in the group's name,
  `group.com.LoganShire.Applications.updates` (`UpdateSignal`), which every
  process can post and hear: Applications posts it when a newest build
  moved, and an app when it asks for an install. It carries nothing;
  whoever hears it reads the database.

## In an app

    import ApplicationUpdates

    // At launch (application(_:didFinishLaunchingWithOptions:),
    // applicationDidFinishLaunching(_:), or the App's init):
    AppUpdates.start()

`AppUpdates.start()` writes the app's build, then checks
(`UpdateChecker`), off the main actor: at launch, each time the app comes
to the foreground, and when Applications announces a change. When the
newest build is newer than the app (`AppVersion`: part by part as numbers,
0.10.2 after 0.9.34, then the build), it shows a notification, "Visor
0.40.1 is available", with Install:

- **only while the app is in the foreground**: a check in the background
  waits until it comes forward;
- **once a build a process**: a newer one is told again;
- **permission** is asked the first time there is one to show; refused,
  nothing is shown.

Opening the notification, or its Install, installs the update
(`UpdateInstaller`):

- **iPhone and iPad**: the build's over-the-air install link is opened;
  iOS asks, then ends the app and replaces it.
- **Mac, most apps** (every client app, Applications' own too): the app
  writes an install request, opens Applications by its bundle id (or brings
  it forward; production's, else the beta's), and quits as Quit would
  (`NSApplication.terminate`). Applications takes the request at launch, or
  at once if it runs (it listens for the Darwin notification), installs the
  newest build with its own install path (MacInstall: checked, the old copy
  to the Trash) and opens the app again (app/Sources/macOS/InstallRequests.swift).
- **Mac, apps that update themselves**: OS Server, Visor Runner and
  Applications Server, which must stop their work in order, register a
  handler before `start`, and it is called instead:

      AppUpdates.register { update in
          // update.installURL: the build's .zip; update.version, update.build
          try await installAndRestart(from: update.installURL)
      }

**Its own notification delegate.** `start` sets the notification center's
delegate only if the app has none. An app with its own asks
`AppUpdates.isUpdateNotification(_:)` in `willPresent` (and answers
`[.banner, .list, .sound]`), passes `AppUpdates.update(from:)` to
`AppUpdates.install(_:)` in `didReceive`, and, if it sets its notification
categories after `start`, includes `NotificationPresenter.notificationCategory`.

**Applications itself** calls `AppUpdates.start(tellsOfUpdates: false)`:
it writes its own build, and tells of its updates as it always has (its
pushes on an iPhone, NewBuildNotices on a Mac).

## The app group

Every app that reads or writes the database needs
`com.apple.security.application-groups` with
`group.com.LoganShire.Applications` in its entitlements, and:

- **iPhone and iPad**: its provisioning profile must grant the group: its
  App ID given the App Groups capability with the group, and the profile
  made again (development and ad hoc, each bundle id, beta and
  production). Applications Server refuses to sign an iPhone app whose
  entitlements ask for what its profile does not allow, so the profiles
  come first, then the entitlement.
- **Mac, macOS 15 and later**: a `group.` app group in an app outside the
  Mac App Store is granted by a provisioning profile too (a Developer ID
  profile whose App ID has the group); without one the system asks the
  user before the app opens the container. Applications Server keeps a Mac
  app's entitlements as built and embeds the bundle id's profile when it
  has one (docs/SERVER.md, "Signing"), so the profile, once in the server's
  profiles folder, is what makes it silent.
- **Without the container** (no entitlement, no profile) `start` logs why
  and does nothing: the app runs as before.

Applications has the entitlement on the Mac (app/app.mac.entitlements), in
the simulator (app/app.simulator.entitlements) and on an iPhone or iPad
(app/app.entitlements), which its one bundle id's profiles grant
(2026-11-01).

### The bundle ids

Every app Applications distributes, and Applications itself, needs the
group in its App ID and its profiles: one bundle id an app, for its Alpha,
Beta, AdHoc and Production builds alike (docs/VARIANTS.md). The server's own
list (its repositories' bundle ids, apps.json and its catalog) is the
authority. An app's helpers and extensions (a widget) need the group only if
they read the database.

## Taking it in another repository

Through rules_swift_package_manager, as with the project's other Swift
packages:

1. The package, by version, in the repository's Package.swift for
   rules_swift_package_manager:

       .package(url: "https://github.com/AttilaTheFun/applications.git", from: "<the first release with it>"),

   (Applications' release tags, v0.10.N; until this repository is public,
   the fetch needs a GitHub token), and its Package.resolved updated.
2. MODULE.bazel: `use_repo(swift_deps, "swiftpkg_applications")`, and, for
   an app also built on Isomer, its Foundation:

       swift_deps.configure_package(
           name = "applications",
           target_deps = {"ApplicationUpdates": ["@@isomer+//:foundation"]},
       )

3. The app's library depends on `@swiftpkg_applications//:ApplicationUpdates`.
4. The entitlement, the profiles (above), and `AppUpdates.start()` at
   launch.

The package's own floor is swift_sql's, iOS 16 and macOS 13. It names
swift_sql from 0.35.0 up, so an app's own pin of it is the one taken.

## What it replaces, and what is left

The library is the way an app learns of its updates; the older ways stay
until every app has taken it:

- **Build schemes** (`applications-<release>-build-<n>`, BuildSchemes):
  the server numbering each production iPhone build and signing it again to
  add its scheme, CI stamping it (`/api/build-scheme`, tools/ci). Since
  2026-11-02 Applications on the iPhone asks iOS about the apps' own link
  schemes instead (whether an app is there, as only iOS knows when one
  was deleted: a deleted app's row stays) and takes the build from the
  database (which). Once every app writes its build, the stamping and the
  numbering go.
- **NewBuildNotices** (Applications on a Mac telling of every app's new
  build) and the server's pushes of other apps' builds: the apps tell of
  their own now, so once they all do, Applications tells only of itself.
- **Link schemes** (`<scheme>://`) are each app's own, one an app: on the
  iPhone, Applications asks iOS whether an app is installed by its scheme.

Not done here:

- Each app adopting it, with the handlers of the ones that update
  themselves.
- The App IDs' App Groups capability and the profiles made again, then
  copied to Applications Server's profiles folder; then the entitlement in
  Applications' iPhone device build.
- A Mac update handler's download: the .zip is on the server's HTTPS
  address, whose certificate is the server's own authority's, so a handler
  pins it as Applications does (pipeline_client) or goes through
  Applications.
- Android, where Applications on Isomer would do the same with a content
  provider in place of the app group.
