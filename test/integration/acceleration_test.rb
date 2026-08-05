# frozen_string_literal: true

require "test_helper"

module Siding
  class AccelerationTest < Minitest::Test
    include TestSupport

    BOOT_MARKER = ["rails", "runner", "puts BootMarker.booted_at"].freeze

    def test_first_invocation_boots_a_warm_application
      refute warm_application?, "a warm application existed before the first invocation"

      result = siding_invoke(*BOOT_MARKER)

      assert_equal 0, result.exitstatus, "invocation failed:\n#{result.stderr}"
      assert warm_application?, "no warm application after the first invocation"
      assert_operator siding_server_pid, :>, 0
    end

    def test_second_invocation_reuses_the_warm_application
      first = siding_invoke(*BOOT_MARKER)
      server_pid = siding_server_pid
      second = siding_invoke(*BOOT_MARKER)

      assert_equal 0, first.exitstatus, first.stderr
      assert_equal 0, second.exitstatus, second.stderr
      assert_equal first.stdout, second.stdout,
                   "the two invocations booted separately: the application was not reused"
      assert_equal server_pid, siding_server_pid, "the second invocation replaced the server"
    end

    def test_a_second_executable_is_served_by_the_same_application
      siding_invoke(*BOOT_MARKER)
      server_pid = siding_server_pid

      result = siding_invoke("rake", "-T")

      assert_equal 0, result.exitstatus, result.stderr
      assert_includes result.stdout, "rake"
      assert_equal server_pid, siding_server_pid, "rake booted an application of its own"
    end

    def test_rspec_is_served_by_the_same_application
      siding_invoke(*BOOT_MARKER)
      server_pid = siding_server_pid

      result = siding_invoke("rspec", "spec/boot_marker_spec.rb")

      assert_equal 0, result.exitstatus, result.stderr
      assert_includes result.stdout, "1 example, 0 failures"
      assert_equal server_pid, siding_server_pid, "rspec booted an application of its own"
    end

    def test_the_command_runs_in_a_worker_rather_than_in_the_server
      result = siding_invoke("rails", "runner", "puts Process.pid")

      assert_equal 0, result.exitstatus, result.stderr
      refute_equal siding_server_pid, result.stdout.to_i,
                   "the command ran inside the server process itself"
    end

    def test_the_worker_runs_in_the_directory_the_developer_invoked_from
      subdirectory = File.join(FIXTURE_APP, "test")

      result = siding_invoke("rails", "runner", "puts Dir.pwd", chdir: subdirectory)

      assert_equal 0, result.exitstatus, result.stderr
      assert_equal File.realpath(subdirectory), File.realpath(result.stdout.strip)
    end

    def test_the_worker_sees_the_environment_of_the_invocation
      result = siding_invoke("rails", "runner", 'puts ENV.fetch("SIDING_TEST_MARKER", "unset")',
                             env: { "SIDING_TEST_MARKER" => "from-the-client" })

      assert_equal 0, result.exitstatus, result.stderr
      assert_equal "from-the-client", result.stdout.strip
    end

    def test_a_variable_absent_from_the_invocation_is_absent_in_the_worker
      siding_invoke("rails", "runner", "nil", env: { "SIDING_TEST_MARKER" => "stale" })

      result = siding_invoke("rails", "runner", 'puts ENV.fetch("SIDING_TEST_MARKER", "unset")')

      assert_equal 0, result.exitstatus, result.stderr
      assert_equal "unset", result.stdout.strip
    end
  end
end
