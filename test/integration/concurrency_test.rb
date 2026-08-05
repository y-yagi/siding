# frozen_string_literal: true

require "test_helper"

module Siding
  class ConcurrencyTest < Minitest::Test
    include TestSupport

    INVOCATIONS = 8

    def test_a_cold_stampede_boots_exactly_one_application
      refute warm_application?, "a warm application existed before the stampede"

      results = invoke_in_parallel(INVOCATIONS) do |index|
        ["rails", "runner", "puts \"worker-#{index}\""]
      end

      assert_all_succeeded(results)
      assert_equal INVOCATIONS, distinct_boot_markers(results).size,
                   "invocations shared a worker process"
      assert_equal 1, state_directories.size,
                   "more than one warm application was booted: #{state_directories.inspect}"
    end

    def test_concurrent_output_does_not_interleave
      siding_invoke("rails", "runner", "nil")

      results = invoke_in_parallel(INVOCATIONS) do |index|
        ["rails", "runner", "50.times { puts \"line-#{index}\" }"]
      end

      assert_all_succeeded(results)
      results.each_with_index do |result, index|
        expected = "line-#{index}\n" * 50

        assert_equal expected, result.stdout, "invocation #{index} received another one's output"
        assert_empty result.stderr
      end
    end

    def test_each_invocation_gets_its_own_exit_status
      siding_invoke("rails", "runner", "nil")

      results = invoke_in_parallel(INVOCATIONS) do |index|
        ["rails", "runner", "exit #{index}"]
      end

      assert_equal (0...INVOCATIONS).to_a, results.map(&:exitstatus)
    end

    def test_the_application_survives_its_workers
      siding_invoke("rails", "runner", "nil")
      server_pid = siding_server_pid

      invoke_in_parallel(INVOCATIONS) { |index| ["rails", "runner", "exit #{index.zero? ? 1 : 0}"] }

      assert_equal server_pid, siding_server_pid, "the server was replaced during the run"
      assert alive?(server_pid), "the server died while serving concurrent invocations"
    end

    private

    def invoke_in_parallel(count)
      barrier = Queue.new
      threads = Array.new(count) do |index|
        Thread.new do
          barrier.pop
          siding_invoke(*yield(index))
        end
      end
      count.times { barrier << :go }
      threads.map(&:value)
    end

    def assert_all_succeeded(results)
      failures = results.reject { |result| result.exitstatus.zero? }

      assert_empty failures.map(&:stderr), "#{failures.size} of #{results.size} invocations failed"
    end

    def distinct_boot_markers(results)
      results.map(&:stdout).uniq
    end

    def state_directories
      Dir.glob(File.join(siding_runtime_dir, Siding::Runtime::NAMESPACE, "*")).select do |path|
        File.directory?(path)
      end
    end
  end
end
