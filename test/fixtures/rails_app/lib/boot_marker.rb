# frozen_string_literal: true

# A lib/ file that is *required at boot* rather than autoloaded.
#
# This distinction is the whole reason the file exists. Rails 8 autoloads lib/ via
# `config.autoload_lib`, and an autoloaded file is not in `$LOADED_FEATURES` after boot unless
# something referenced it -- so it would never appear in a manifest derived from that diff.
# config/application.rb requires this file explicitly, which puts it in the
# manifest and makes it a genuine boot-time dependency: editing it must invalidate the warm
# application, and the staleness matrix asserts exactly that.
module BootMarker
  # Captured once, at boot. If a warm application ever serves a stale copy of this file, this
  # value is how a test sees it: the constant still holds the old string.
  VALUE = "boot-marker-v1"

  # Recomputed per call rather than captured, so tests can tell "the process was replaced"
  # apart from "the file was re-read".
  def self.booted_at
    @booted_at ||= Time.now.to_f
  end
end

BootMarker.booted_at
