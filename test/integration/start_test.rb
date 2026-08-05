# frozen_string_literal: true

require "test_helper"
require "siding/client"

module Siding
  class StartTest < Minitest::Test
    include TestSupport
    include TerminalTests

    RESOLUTION_PROBE = ["rails", "runner", 'puts ENV.fetch("SIDING_RESOLUTION", "none")'].freeze

    def test_it_boots_a_warm_application_without_running_a_command
      result = siding_invoke("start")

      assert_equal 0, result.exitstatus, "start did not report that it had booted anything"
      assert warm_application?, "start booted nothing"
      assert_empty result.stdout, "start wrote its own report to stdout"
      assert_empty result.stderr, "start wrote its own report to stderr"
    end

    def test_starting_what_is_already_warm_leaves_it_alone
      siding_invoke("start")
      incumbent = siding_server_pid

      assert_equal 0, siding_invoke("start").exitstatus

      assert_equal incumbent, siding_server_pid, "a second start replaced the warm application"
    end

    def test_the_application_it_boots_serves_the_next_invocation
      siding_invoke("start")
      incumbent = siding_server_pid

      result = siding_invoke(*RESOLUTION_PROBE)

      assert_equal 0, result.exitstatus, result.stderr
      refute_equal "none", result.stdout.strip, "the command start had warmed up ran unaccelerated"
      assert_equal incumbent, siding_server_pid, "the invocation booted its own application anyway"
    end

    def test_it_boots_nothing_when_the_tool_is_inactive
      result = siding_invoke("start", env: { "SIDING_DISABLE" => "1" })

      refute_equal 0, result.exitstatus, "start claimed to have booted something while opted out"
      refute warm_application?, "start booted an application the developer had opted out of"
    end

    def test_a_boot_that_outlasts_the_bound_is_reported_rather_than_waited_out
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = siding_invoke("start", env: { "SIDING_TIMEOUT" => "0.05" })
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      refute_equal 0, result.exitstatus, "start reported a boot it had stopped waiting for"
      assert_operator elapsed, :<, Siding::Client::DEFAULT_BOOT_TIMEOUT / 2,
                      "start waited past its own bound"

      # The boot start walked away from is still in flight, and the base teardown stops the server
      # it can find a record of. Letting it finish publishing first is the difference between a
      # clean stop and a process this test leaks into the next one.
      await_warm_application
    end

    def test_it_names_the_application_it_booted
      session = open_siding_terminal("start")
      expect_on(session, /is warm/, timeout: 60, message: "start said nothing about what it booted")

      assert_match(/is warm -- pid #{siding_server_pid}/, session.screen,
                   "start did not name the application it had booted")
    end

    def test_it_says_when_there_was_nothing_to_do
      siding_invoke("start")

      session = open_siding_terminal("start")
      expect_on(session, /already warm/, timeout: 30,
                         message: "start said nothing about the application it found")

      assert_match(/is already warm -- pid #{siding_server_pid}/, session.screen)
    end

    def test_it_gives_the_reason_it_booted_nothing
      session = open_siding_terminal("start", env: { "SIDING_DISABLE" => "1" })
      expect_on(session, /cannot boot/, timeout: 30, message: "start refused without saying why")

      assert_match(/SIDING_DISABLE is set/, session.screen,
                   "start did not name what was stopping it")
    end

    def test_it_says_where_to_look_when_a_boot_does_not_finish_in_time
      session = open_siding_terminal("start", env: { "SIDING_TIMEOUT" => "0.05" })
      expect_on(session, /did not boot/, timeout: 30,
                         message: "start abandoned a boot without saying so")

      assert_match(/boot\.log/, session.screen, "start did not say where the boot's output went")

      await_warm_application
    end

    private

    def await_warm_application(timeout: 30.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      sleep 0.05 until warm_application? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end
  end
end
