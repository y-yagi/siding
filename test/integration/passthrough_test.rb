# frozen_string_literal: true

require "test_helper"

module Siding
  class PassthroughTest < Minitest::Test
    include TestSupport

    def test_an_executable_outside_the_accelerated_set_still_runs
      result = siding_invoke("ruby", "-e", 'puts "plain ruby"')

      assert_equal 0, result.exitstatus, result.stderr
      assert_equal "plain ruby\n", result.stdout
      refute warm_application?, "an unaccelerated command booted a warm application"
    end

    def test_an_out_of_scope_rails_command_still_runs
      result = siding_invoke("rails", "dev:cache", "--help")

      assert_equal 0, result.exitstatus, result.stderr
      assert_includes result.stdout, "Usage:"
      refute warm_application?, "an out-of-scope command booted a warm application"
    end

    def test_siding_disable_turns_the_tool_off
      result = siding_invoke("rake", "-T", env: { "SIDING_DISABLE" => "1" })

      assert_equal 0, result.exitstatus, result.stderr
      assert_includes result.stdout, "rake"
      refute warm_application?, "the tool booted an application while disabled"
    end

    def test_siding_disable_set_to_a_falsy_value_leaves_the_tool_on
      result = siding_invoke("rake", "-T", env: { "SIDING_DISABLE" => "0" })

      assert_equal 0, result.exitstatus, result.stderr
      assert warm_application?, "a falsy SIDING_DISABLE was treated as disabling the tool"
    end

    def test_a_command_outside_a_rails_application_still_runs
      Dir.mktmpdir("siding-not-an-app") do |directory|
        result = siding_invoke("ruby", "-e", "puts Dir.pwd", chdir: directory)

        assert_equal 0, result.exitstatus, result.stderr
        assert_equal File.realpath(directory), File.realpath(result.stdout.strip)
        refute warm_application?
      end
    end

    def test_the_exit_status_of_an_unaccelerated_command_is_its_own
      result = siding_invoke("ruby", "-e", "exit 7")

      assert_equal 7, result.exitstatus
    end
  end
end
