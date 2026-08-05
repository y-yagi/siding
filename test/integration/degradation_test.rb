# frozen_string_literal: true

require "test_helper"
require "siding/client"

module Siding
  class DegradationTest < Minitest::Test
    include TestSupport

    PROBE = ["rails", "runner", 'puts ENV.fetch("SIDING_RESOLUTION", "none")'].freeze

    def teardown
      restore_broken_directories
      super
    ensure
      @broken_directories&.each { |path| FileUtils.remove_entry(path) if File.directory?(path) }
    end

    def test_an_unwritable_runtime_directory_degrades_rather_than_failing
      result = siding_invoke(*PROBE, env: { "XDG_RUNTIME_DIR" => unwritable_directory })

      assert_equal 0, result.exitstatus, "the command failed because the tool could not run:\n#{result.stderr}"
      assert_equal "none", result.stdout.strip, "the tool accelerated from a directory it cannot use"
      assert_empty result.stderr, "the tool explained its own problem on the command's stderr"
    end

    def test_a_degraded_run_is_byte_identical_to_an_unaccelerated_one
      script = '3.times { |i| puts "out-#{i}"; warn "err-#{i}" }'

      degraded = siding_invoke("rails", "runner", script,
                               env: { "XDG_RUNTIME_DIR" => unwritable_directory })
      direct = unaccelerated_invoke("rails", "runner", script)

      assert_equal direct.stdout, degraded.stdout
      assert_equal direct.stderr, degraded.stderr
      assert_equal direct.exitstatus, degraded.exitstatus
    end

    def test_a_runtime_path_that_is_not_a_directory_degrades
      path = File.join(Dir.mktmpdir("siding-degradation"), "occupied")
      File.write(path, "not a directory\n")
      (@broken_directories ||= []) << File.dirname(path)

      result = siding_invoke(*PROBE, env: { "XDG_RUNTIME_DIR" => path })

      assert_equal 0, result.exitstatus, result.stderr
      assert_equal "none", result.stdout.strip
    end

    def test_a_runtime_path_too_long_for_a_socket_degrades
      root = Dir.mktmpdir("siding-degradation")
      (@broken_directories ||= []) << root
      deep = File.join(root, *Array.new(12) { "d" * 20 })
      FileUtils.mkdir_p(deep)

      result = siding_invoke(*PROBE, env: { "XDG_RUNTIME_DIR" => deep })

      assert_equal 0, result.exitstatus, result.stderr
      assert_equal "none", result.stdout.strip
      refute File.socket?(File.join(deep, "siding", "sock")), "a socket was bound at an unusable path"
    end

    def test_a_boot_that_outlasts_the_bound_runs_unaccelerated_rather_than_hanging
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = siding_invoke(*PROBE, env: { "SIDING_TIMEOUT" => "0.05" })
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal 0, result.exitstatus, "the command failed while the tool gave up waiting:\n#{result.stderr}"
      assert_equal "none", result.stdout.strip, "the tool served a boot it had already stopped waiting for"
      assert_empty result.stderr, "the tool explained its own waiting on the command's stderr"
      assert_operator elapsed, :<, Siding::Client::DEFAULT_BOOT_TIMEOUT / 2,
                      "the invocation waited past its own bound"

      # The boot the client walked away from is still in flight, and the base teardown stops the
      # server it can find a record of. Letting it finish publishing first is the difference
      # between a clean stop and a process this test leaks into the next one.
      await_warm_application
    end

    private

    def await_warm_application(timeout: 30.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      sleep 0.05 until warm_application? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end

    def restore_broken_directories
      @broken_directories&.each do |path|
        File.chmod(0o700, path)
      rescue SystemCallError
        nil
      end
    end

    def unwritable_directory
      @unwritable_directory ||= begin
        path = Dir.mktmpdir("siding-degradation")
        File.chmod(0o500, path)
        (@broken_directories ||= []) << path
        path
      end
    end
  end
end
