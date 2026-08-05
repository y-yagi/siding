# frozen_string_literal: true

require "test_helper"

module Siding
  class EnvOverrideTest < Minitest::Test
    include TestSupport

    def setup
      siding_invoke("rails", "runner", "print 1")
      @server_pid = siding_server_pid
      refute_nil @server_pid, "no warm application to test against"
    end

    def test_a_variable_set_for_one_invocation_is_seen_by_that_invocation
      result = read_variable("FEATURE_FLAG", env: { "FEATURE_FLAG" => "on" })

      assert_equal '"on"', result
    end

    def test_consecutive_invocations_see_their_own_values
      assert_equal '"first"', read_variable("ROUND", env: { "ROUND" => "first" })
      assert_equal '"second"', read_variable("ROUND", env: { "ROUND" => "second" })
      assert_equal "nil", read_variable("ROUND")

      assert_equal @server_pid, siding_server_pid,
                   "the environment change was served by a different server, so nothing was reused"
    end

    def test_a_variable_unset_since_the_boot_is_unset_for_the_command
      assert_equal '"present"', read_variable("TEMPORARY", env: { "TEMPORARY" => "present" })
      assert_equal "nil", read_variable("TEMPORARY")
    end

    def test_an_empty_value_is_distinguished_from_an_absent_one
      assert_equal '""', read_variable("EMPTY", env: { "EMPTY" => "" })
      assert_equal "nil", read_variable("EMPTY")
    end

    def test_the_value_matches_an_unaccelerated_run
      command = ["rails", "runner", "print ENV['SURPRISE'].inspect"]
      env = { "SURPRISE" => "not in any list" }

      assert_equal unaccelerated_invoke(*command, env: env).stdout,
                   siding_invoke(*command, env: env).stdout
    end

    def test_the_working_directory_is_the_invocations_own
      from_subdirectory = siding_invoke("rails", "runner", "print Dir.pwd",
                                        chdir: File.join(FIXTURE_APP, "app"))

      assert_equal File.join(FIXTURE_APP, "app"), from_subdirectory.stdout
    end

    private

    def read_variable(name, env: {})
      siding_invoke("rails", "runner", "print ENV[#{name.inspect}].inspect", env: env).stdout
    end
  end
end
