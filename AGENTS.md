# Applications, for agents

Read README.md first, then docs/APPLICATIONS_PLAN.md: what is built, and
what comes next.

- **This repository is public.** Never add a person's name (write "the
  owner"), a device or host name, a real IP address or hostname (use
  192.0.2.x, 100.64.0.x, example.com, example-mac.local; 10.0.0.x where a
  test needs a private LAN address), a private project's name, or any
  secret, key, token, team ID, UDID or provisioning profile. Before
  pushing, check `git grep -n -i -E '<the patterns>'`, the patterns being:
  - the owner's first and last names (the bundle ids' `com.<Owner>` prefix
    aside, which stays);
  - the owner's computers' names and Bonjour names, and "MacBook" or "Mac
    mini" said of a particular person's machine;
  - the home LAN's real addresses (its 192.168 range) and the tailnet's
    real 100.x addresses (anything in 100.64.0.0/10 that is not a
    documentation example);
  - the names of the owner's private repositories and projects;
  - personal email domains (`@gmail` and the like).
- **Trusted builds and proofs come from CI alone,** on the owner's
  self-hosted runner, which leases containers and VMs from OS Server. Agents push
  branches and open pull requests, as the Claude app, and may lease machines
  for their own checks, but nothing they make by hand is published as a
  build or filed as a proof.
- **Nothing goes to main but through a pull request.** Agents merge their
  own once CI is green and the branch is up to date with main, except those
  that touch a protected file (.github/CODEOWNERS: CI, publishing and
  signing, the agents' rules, the license), which need the owner's review.
- **Build and test on Linux, in a container:** `tools/ci/container_build.sh`
  builds in the Linux container it runs in (or, run on the Mac, leases one
  from OS Server), the apps and the server with
  rules_applecross, then runs the tests Linux can (README, "On Linux").
  The app's iPhone and iPad tests build there too
  (`--//tools/ci:ios_tests_anywhere`) and run on an iOS lease
  (`tools/ci/ios_lease_tests.sh`, `oss machine xctest`), which makes the
  proof when CI is run by hand (to propose a release, or to bisect). Lease a Mac VM only for what needs a Mac: the Mac's
  and the server's tests, a device build signed with the team's identity. rules_apple and apple_support are held at rules_applecross's
  versions, with its patches (third_party/patches/applecross, copied from
  the commit MODULE.bazel names): moving either means its patches for the
  new version.
- **ApplicationUpdates is a Swift package too** (Package.swift at the root,
  for the other repositories, over libraries/application_updates, which
  Bazel builds here): a source or dependency added there goes in both, and
  `swift test` and `bazel test //libraries/application_updates/...` both
  pass, on Linux as on a Mac (Apple's frameworks behind `canImport`).
  docs/Updates.md has the design.
- **Secrets:**
  - the server's tokens and passwords, the connection codes and the signing
    identities never go in a message, a log or a commit;
  - the signing team is in `.bazelrc.user`, which is not checked in;
  - the signing identities, the profiles and the notary key live on
    Applications Server's Mac, which signs every build CI sends; CI holds
    none of them, nor the password, only its OIDC token (docs/CI.md).
- **Standalone:** the server and the app stand on nothing of another
  project's: no other server is asked before a build is published or
  made production, and the docs name no other project's tools. A build is
  production only when a published release's CI sends it (docs/CI.md).
