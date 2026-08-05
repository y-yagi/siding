# frozen_string_literal: true

require "test_helper"

module Siding
  class DoctorTest < Minitest::Test
    include TestSupport
    include TerminalTests
    include FixtureEdits

    BOOT_MARKER = ["rails", "runner", "puts BootMarker.booted_at"].freeze

    TAIL = /(recent|no changes have cost anything yet|nothing running)/

    def test_it_reports_acceleration_status_and_what_is_warm
      siding_invoke(*BOOT_MARKER, env: { "SIDING_WATCH" => "events" })

      assert warm_application?, "the setup invocation booted nothing for doctor to report on"
      revision = siding_server_info["revision_label"]
      report = run_doctor

      assert_match(/siding #{Regexp.escape(Siding::VERSION)}/, report)
      assert_match(/active\s+yes/, report, "doctor did not say the tool was active")
      assert_match(/warm\s+pid #{siding_server_pid}/, report, "doctor did not name the warm application")
      assert_match(/revision\s+#{Regexp.escape(revision)}/, report,
                   "doctor did not report the revision being served")
      assert_match(/watch\s+events \(watchcat\)/, report,
                   "doctor did not report which wake source the restarter was using")
    end

    def test_it_reports_the_most_recent_staleness_event_and_its_trigger
      siding_invoke(*BOOT_MARKER)
      edit_fixture("config/initializers/fixture_marker.rb") do |source|
        source.sub("initializer-v1", "initializer-v2")
      end
      siding_invoke(*BOOT_MARKER)

      report = run_doctor

      assert_match(/recent/, report, "doctor reported no history after a rebuild")
      assert_match(/rebuild/, report, "doctor did not name how the staleness was resolved")
      assert_match(/fixture_marker\.rb/, report, "doctor did not name what triggered the rebuild")
    end

    def test_the_history_outlives_the_server_that_recorded_it
      siding_invoke(*BOOT_MARKER)
      edit_fixture("config/initializers/fixture_marker.rb") do |source|
        source.sub("initializer-v1", "initializer-v3")
      end
      siding_invoke(*BOOT_MARKER)
      siding_invoke("stop")

      refute warm_application?, "the setup did not leave the project without a server"
      report = run_doctor

      assert_match(/warm\s+nothing running/, report)
      assert_match(/rebuild/, report, "the recorded history did not survive the server that wrote it")
      assert_match(/fixture_marker\.rb/, report)
    end

    def test_it_explains_why_acceleration_is_unavailable
      report = run_doctor(env: { "SIDING_DISABLE" => "1" })

      assert_match(/active\s+no -- SIDING_DISABLE is set/, report)
    end

    def test_it_reports_the_accelerated_and_passed_through_command_table
      report = run_doctor

      assert_match(/accelerated:\s+rails, rake, rspec, test/, report,
                   "doctor did not list the accelerated executables")
      assert_match(/passed through:\s+rails dev:cache, rails server -d, and everything else/, report,
                   "doctor did not name both rails carve-outs")
    end

    def test_it_answers_with_nothing_running
      refute warm_application?, "this test has to be the one with nothing warm"

      report = run_doctor

      assert_match(/warm\s+nothing running/, report)
      assert_match(/platform/, report)
      assert_match(/framework\s+Rails \d/, report, "doctor did not report the resolved framework version")
      assert_match(/runtime\s+#{Regexp.escape(siding_runtime_dir)}/, report)
    end

    def test_its_exit_status_reports_whether_acceleration_is_available
      available = siding_invoke("doctor")
      unavailable = siding_invoke("doctor", env: { "SIDING_DISABLE" => "1" })

      assert_equal 0, available.exitstatus
      assert_equal 1, unavailable.exitstatus
    end

    private

    def run_doctor(env: {})
      session = open_siding_terminal("doctor", env: env)
      expect_on(session, TAIL, timeout: 30, message: "doctor printed no report")
      session.screen
    end
  end
end
