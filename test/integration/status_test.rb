# frozen_string_literal: true

require "test_helper"

module Siding
  class StatusTest < Minitest::Test
    include TestSupport
    include TerminalTests

    BOOT_MARKER = ["rails", "runner", "puts BootMarker.booted_at"].freeze
    TAIL = /(recent|idle exit|no warm application|no Rails application)/

    def test_it_names_the_warm_application_and_what_it_was_built_from
      siding_invoke(*BOOT_MARKER)

      assert warm_application?, "the setup invocation booted nothing for status to report on"
      info = siding_server_info
      report = run_status

      assert_match(/is warm/, report, "status did not say an application was warm")
      assert_match(/siding #{Regexp.escape(Siding::VERSION)}/, report)
      assert_match(/server\s+pid #{siding_server_pid}/, report, "status did not name the process")
      assert_match(/revision\s+#{Regexp.escape(info['revision_label'])}/, report,
                   "status did not report the source state the application was built from")
    end

    def test_it_reports_which_watch_mode_the_restarter_is_using
      siding_invoke(*BOOT_MARKER, env: { "SIDING_WATCH" => "events" })

      report = run_status

      assert_match(/watch\s+events \(watchcat\)/, report,
                   "status did not report that the restarter was watching for events")
    end

    def test_it_reports_poll_mode_when_selected
      siding_invoke(*BOOT_MARKER, env: { "SIDING_WATCH" => "poll" })

      report = run_status

      assert_match(/watch\s+poll \(watchcat\)/, report,
                   "status did not report that the restarter was polling through watchcat")
    end

    def test_it_reports_when_the_application_booted_and_what_it_has_served
      siding_invoke(*BOOT_MARKER)
      siding_invoke(*BOOT_MARKER)

      report = run_status

      assert_match(/booted \d/, report, "status did not report when the application booted")
      assert_match(/served\s+\d+ invocation/, report, "status did not report what it has served")
      assert_match(/idle exit\s+/, report, "status did not report when the application will leave")
    end

    def test_its_exit_status_answers_without_the_prose
      cold = siding_invoke("status")

      refute_equal 0, cold.exitstatus, "status reported a warm application before anything booted"

      siding_invoke(*BOOT_MARKER)

      assert_equal 0, siding_invoke("status").exitstatus,
                   "status did not report the warm application the invocation just booted"
    end

    def test_stopping_is_explicit_and_status_confirms_it
      siding_invoke(*BOOT_MARKER)

      assert_equal 0, siding_invoke("stop").exitstatus
      refute warm_application?, "stop left a warm application behind"

      report = run_status

      assert_match(/no warm application/, report, "status still reported something warm after stop")
      refute_equal 0, siding_invoke("status").exitstatus
    end

    def test_stopping_what_is_already_stopped_succeeds
      siding_invoke(*BOOT_MARKER)
      siding_invoke("stop")

      assert_equal 0, siding_invoke("stop").exitstatus
      assert_equal 0, siding_invoke("stop").exitstatus
    end

    private

    def run_status(env: {})
      session = open_siding_terminal("status", env: env)
      expect_on(session, TAIL, timeout: 30, message: "status printed no report")
      session.screen
    end
  end
end
