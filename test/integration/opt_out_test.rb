# frozen_string_literal: true

require "test_helper"

module Siding
  class OptOutTest < Minitest::Test
    include TestSupport

    RESOLUTION_PROBE = ["rails", "runner", 'puts ENV.fetch("SIDING_RESOLUTION", "none")'].freeze

    def test_a_single_invocation_can_opt_out
      result = siding_invoke(*RESOLUTION_PROBE, env: { "SIDING_DISABLE" => "1" })

      assert_equal 0, result.exitstatus, result.stderr
      assert_equal "none", result.stdout.strip, "the command was accelerated despite SIDING_DISABLE"
      refute warm_application?, "a server was booted for an invocation that opted out"
    end

    def test_opting_out_is_honoured_while_a_warm_application_exists
      warm = siding_invoke(*RESOLUTION_PROBE)

      assert warm_application?, "the setup invocation did not boot anything to opt out of"
      server_pid = siding_server_pid
      refute_equal "none", warm.stdout.strip, "the setup invocation was not accelerated"

      opted_out = siding_invoke(*RESOLUTION_PROBE, env: { "SIDING_DISABLE" => "1" })

      assert_equal 0, opted_out.exitstatus, opted_out.stderr
      assert_equal "none", opted_out.stdout.strip, "the warm application served an opted-out command"
      assert_equal server_pid, siding_server_pid, "opting out killed the warm application"
    end

    def test_an_off_value_leaves_the_tool_active
      result = siding_invoke(*RESOLUTION_PROBE, env: { "SIDING_DISABLE" => "0" })

      assert_equal 0, result.exitstatus, result.stderr
      refute_equal "none", result.stdout.strip, "SIDING_DISABLE=0 disabled the tool"
    end

    def test_the_test_environment_stays_active
      result = siding_invoke(*RESOLUTION_PROBE, env: { "RAILS_ENV" => "test" })

      assert_equal 0, result.exitstatus, result.stderr
      refute_equal "none", result.stdout.strip, "the tool declined to accelerate RAILS_ENV=test"
      assert warm_application?
    end

    def test_the_development_environment_stays_active
      result = siding_invoke(*RESOLUTION_PROBE, env: { "RAILS_ENV" => "development" })

      assert_equal 0, result.exitstatus, result.stderr
      refute_equal "none", result.stdout.strip
    end

    def test_a_production_like_environment_is_inactive
      assert_declines_environment("production")
    end

    def test_an_unrecognized_environment_name_is_inactive
      assert_declines_environment("qa-sandbox")
    end

    private

    def assert_declines_environment(name)
      through_tool = siding_invoke(*RESOLUTION_PROBE, env: { "RAILS_ENV" => name })
      directly = unaccelerated_invoke(*RESOLUTION_PROBE, env: { "RAILS_ENV" => name })

      refute warm_application?, "a server was booted for the #{name.inspect} environment"
      assert_equal directly.exitstatus, through_tool.exitstatus,
                   "the tool changed the outcome of a command it declined to accelerate"
      assert_equal directly.stdout, through_tool.stdout
    end
  end
end
