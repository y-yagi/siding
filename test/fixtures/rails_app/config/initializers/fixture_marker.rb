# frozen_string_literal: true

# A boot-time initializer, and the fixture's only reader of the environment.
#
# Two staleness categories meet in this file, which is why it is one file and not two:
#
#   * Editing an initializer must invalidate the warm application. Initializers run once, at
#     boot, and are never re-run by the reloader -- so this is `scope: reboot`.
#   * Reading ENV at boot means the value is baked into the warm application. An invocation
#     that supplies a different value must not be served from an application booted with the
#     old one, which is what makes ENV part of the manifest.
#
# A test can distinguish the two failure modes: a stale initializer shows up as an old
# MARKER, a stale environment as an old FIXTURE_ENV.
module FixtureMarker
  MARKER = "initializer-v1"

  # Read at boot, deliberately. FIXTURE_ENV is not in the per-invocation allowlist, so
  # changing it is a reboot trigger rather than something a worker can apply after fork.
  FIXTURE_ENV = ENV.fetch("FIXTURE_ENV", "unset")
end
