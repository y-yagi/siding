# frozen_string_literal: true

require "test_helper"

module Siding
  module RestarterCases
    ABSORB_TIMEOUT = 45.0

    def siding_env(overrides = {})
      super({ "SIDING_WATCH" => watch_mode }.merge(overrides))
    end

    def test_a_change_made_while_idle_is_absorbed_before_the_next_invocation
      incumbent = warm_up

      edit_fixture("config/initializers/fixture_marker.rb") do |source|
        source.sub("initializer-v1", "initializer-v4")
      end

      replacement = wait_for_replacement(incumbent)

      refute_nil replacement, "the restarter never replaced the application it knew was stale"

      observation = observe("FixtureMarker::MARKER")

      assert_equal "initializer-v4", observation.value
      assert_equal "fresh", observation.resolution,
                   "the developer paid for a boot that had already happened"
      assert_equal replacement, siding_server_pid,
                   "the invocation was served by something other than the restarter's replacement"
    end

    def test_the_replaced_application_leaves_and_leaves_the_replacement_working
      incumbent = warm_up

      edit_fixture("lib/boot_marker.rb") { |source| source.sub("boot-marker-v1", "boot-marker-v4") }
      replacement = wait_for_replacement(incumbent)

      refute_nil replacement
      assert wait_until { !alive?(incumbent) },
             "the replaced application was still running long after it was replaced"
      assert warm_application?, "the handover left no usable warm application"

      observation = observe("BootMarker::VALUE")

      assert_equal "boot-marker-v4", observation.value
      assert_equal replacement, siding_server_pid
    end

    private

    Observation = Struct.new(:booted_at, :resolution, :revision, :value, keyword_init: true)

    def warm_up
      observe
      pid = siding_server_pid

      refute_nil pid, "no warm application to stand by"
      pid
    end

    def wait_for_replacement(incumbent)
      wait_until(ABSORB_TIMEOUT) do
        pid = siding_server_info&.dig("pid")
        pid && pid != incumbent
      end
      pid = siding_server_pid
      pid == incumbent ? nil : pid
    end

    def wait_until(timeout = 10.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return true if yield
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.1
      end
    end

    def observe(expression = '"-"')
      script = "puts [BootMarker.booted_at, ENV['SIDING_RESOLUTION'], ENV['SIDING_REVISION'], " \
               "(#{expression})].join(' ')"
      result = siding_invoke("rails", "runner", script)

      assert_equal 0, result.exitstatus, "invocation failed:\n#{result.stderr}"
      siding_server_pid

      fields = result.stdout.split.last(4)
      Observation.new(booted_at: fields[0], resolution: fields[1], revision: fields[2],
                      value: fields[3])
    end
  end

  class RestarterEventsTest < Minitest::Test
    include TestSupport
    include FixtureEdits
    include RestarterCases

    def watch_mode = "events"

    def test_repeated_invocations_against_a_warm_application_fork_cleanly
      warm_up

      5.times do |i|
        command = ["rails", "runner", "puts \"invocation #{i}\""]
        accelerated = siding_invoke(*command)
        unaccelerated = unaccelerated_invoke(*command)

        assert_equal 0, accelerated.exitstatus, "invocation #{i} failed:\n#{accelerated.stderr}"
        assert_equal unaccelerated.stdout, accelerated.stdout, "invocation #{i} stdout differs"
        assert_equal unaccelerated.stderr, accelerated.stderr, "invocation #{i} stderr differs"
      end
    end
  end

  class RestarterPollTest < Minitest::Test
    include TestSupport
    include FixtureEdits
    include RestarterCases

    def watch_mode = "poll"
  end
end
