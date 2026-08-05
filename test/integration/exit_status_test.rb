# frozen_string_literal: true

require "test_helper"

module Siding
  class ExitStatusTest < Minitest::Test
    include TestSupport

    def test_a_successful_command_exits_zero_both_ways
      assert_same_status("rails", "runner", "exit 0")
    end

    def test_an_explicit_exit_code_is_reproduced
      status = assert_same_status("rails", "runner", "exit 42")

      assert_equal 42, status.exitstatus
    end

    def test_the_edge_exit_codes_are_reproduced
      assert_equal 255, assert_same_status("rails", "runner", "exit 255").exitstatus
      assert_equal 1, assert_same_status("rails", "runner", "raise 'boom'").exitstatus
    end

    def test_death_by_signal_is_reproduced_as_death_by_signal
      status = assert_same_status("rails", "runner", "Process.kill('TERM', Process.pid); sleep 5")

      assert_equal 15, status.termsig, "the command did not die of SIGTERM"
      assert_nil status.exitstatus, <<~MESSAGE
        the tool turned death by signal into an exit code. A shell can see the difference: this
        status has to report `termsig`, not 128 + 15.
      MESSAGE
    end

    def test_an_interrupt_is_reproduced_including_ruby_s_own_message
      status = assert_same_status("rails", "runner", "Process.kill('INT', Process.pid); sleep 5")

      assert_equal 2, status.termsig
      assert_nil status.exitstatus
    end

    def test_a_signal_sent_to_the_client_kills_the_command_and_is_reproduced
      accelerated = signal_a_running_command(accelerated: true, signal: "TERM")
      unaccelerated = signal_a_running_command(accelerated: false, signal: "TERM")

      assert_equal unaccelerated.termsig, accelerated.termsig,
                   "the accelerated run did not die the way the unaccelerated one did"
      assert_equal 15, accelerated.termsig
      assert_nil accelerated.exitstatus
    end

    def test_a_forwarded_interrupt_ends_the_command_promptly
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status = signal_a_running_command(accelerated: true, signal: "INT")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal 2, status.termsig, "the interrupt did not reach the command"
      assert_operator elapsed, :<, 2.0, "the interrupt took #{elapsed.round(2)}s to take effect"
    end

    private

    def assert_same_status(*argv)
      accelerated = siding_invoke(*argv)
      unaccelerated = unaccelerated_invoke(*argv)

      assert_same_field(unaccelerated.exitstatus, accelerated.exitstatus, "exit code differs for #{argv.inspect}")
      assert_same_field(unaccelerated.termsig, accelerated.termsig, "termsig differs for #{argv.inspect}")
      accelerated.status
    end

    def assert_same_field(expected, actual, message)
      expected.nil? ? assert_nil(actual, message) : assert_equal(expected, actual, message)
    end

    def signal_a_running_command(accelerated:, signal:)
      ready = File.join(scratch_dir, "running-#{accelerated}")
      script = "File.write(#{ready.inspect}, Process.pid); sleep 30"
      command = accelerated ? [RbConfig.ruby, EXE] : %w[bundle exec]

      pid = Process.spawn(siding_env, *command, "rails", "runner", script,
                          chdir: FIXTURE_APP, out: File::NULL, err: File::NULL)
      track_pid(pid)
      assert wait_until(60) { File.file?(ready) }, "the command never started"

      # Warm up the fixture's own pid so a leaked worker is caught by teardown even when the
      # assertion above fails.
      track_pid(File.read(ready).to_i)

      Process.kill(signal, pid)
      _, status = Process.waitpid2(pid)
      status
    end

    def scratch_dir
      @scratch_dir ||= Dir.mktmpdir("siding-exit-status")
    end

    def teardown
      super
    ensure
      FileUtils.remove_entry(@scratch_dir) if @scratch_dir && File.directory?(@scratch_dir)
    end

    def wait_until(timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return true if yield
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
    end
  end
end
