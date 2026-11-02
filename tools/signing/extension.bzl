"""The builder's own signing values, from the environment, not the repo.

`@pipeline_signing//:signing.bzl` defines TEAM_ID: the Apple team to sign
device builds with, from PIPELINE_TEAM_ID, or a placeholder. Set it for your
builds in a `.bazelrc.user` at the workspace root (it is not checked in):

    common --repo_env=PIPELINE_TEAM_ID=<your team id>

Simulator and Mac builds need nothing; an iPhone build needs your team's
development profile for the app's bundle id, with push notifications.
"""

def _signing_impl(rctx):
    team = rctx.getenv("PIPELINE_TEAM_ID", "YOUR_TEAM_ID") or "YOUR_TEAM_ID"
    rctx.file("BUILD.bazel", 'exports_files(["signing.bzl"])\n')
    rctx.file("signing.bzl", 'TEAM_ID = "%s"\n' % team)

_signing = repository_rule(implementation = _signing_impl)

def _extension_impl(_mctx):
    _signing(name = "pipeline_signing")

signing = module_extension(implementation = _extension_impl)
