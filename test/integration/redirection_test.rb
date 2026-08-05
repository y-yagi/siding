# frozen_string_literal: true

require "test_helper"
require "shellwords"

module Siding
  class RedirectionTest < Minitest::Test
    include TestSupport
    include TerminalTests

    Capture = Struct.new(:stdout_file, :stderr_file, :shell_stdout, :shell_stderr, :status,
                         keyword_init: true) do
      def exitstatus = status.exitstatus
    end

    def test_a_boot_does_not_write_its_notice_into_a_redirected_capture
      refute warm_application?, "this test has to be the one that boots"

      accelerated = redirect("rails", "runner", 'puts "payload"', accelerated: true)

      assert_equal "payload\n", accelerated.stdout_file
      assert_empty accelerated.stderr_file
      assert_empty accelerated.shell_stdout, "the tool wrote to a stream the developer redirected away"
      assert_empty accelerated.shell_stderr
    end

    def test_redirected_streams_are_byte_identical_to_an_unaccelerated_run
      script = '3.times { |i| puts "out-#{i}"; warn "err-#{i}" }'

      assert_identical_redirection("rails", "runner", script)
    end

    def test_output_without_a_trailing_newline_survives_redirection
      assert_identical_redirection("rails", "runner", 'print "no newline"')
    end

    def test_a_large_redirected_capture_is_complete
      accelerated = assert_identical_redirection("rails", "runner", "5000.times { |i| puts i }")

      assert_equal 5000, accelerated.stdout_file.lines.size
      assert_equal "4999\n", accelerated.stdout_file.lines.last
    end

    def test_piped_output_reaches_the_next_command_intact
      accelerated = through_a_pipe("rails", "runner", "1000.times { |i| puts i }", accelerated: true)
      unaccelerated = through_a_pipe("rails", "runner", "1000.times { |i| puts i }", accelerated: false)

      assert_equal unaccelerated, accelerated
      assert_equal "1000\n", accelerated
    end

    def test_the_command_sees_a_redirected_stream_as_not_a_terminal
      assert_identical_redirection("rails", "runner", 'puts $stdout.tty?; warn $stderr.tty?')
    end

    def test_verbose_output_stays_out_of_a_redirected_capture
      refute warm_application?, "this test has to be the one that boots, so there is plenty to say"

      verbose = redirect("rails", "runner", 'puts "payload"', accelerated: true,
                                            env: { "SIDING_LOG" => "1" })

      assert_equal "payload\n", verbose.stdout_file
      assert_empty verbose.stderr_file, "SIDING_LOG put the tool's output on the command's stderr"
      assert_empty verbose.shell_stdout
      assert_empty verbose.shell_stderr
    end

    def test_a_verbose_run_is_byte_identical_to_an_unaccelerated_one
      script = '2.times { |i| puts "out-#{i}"; warn "err-#{i}" }'

      verbose = redirect("rails", "runner", script, accelerated: true, env: { "SIDING_LOG" => "1" })
      direct = redirect("rails", "runner", script, accelerated: false)

      assert_equal direct.stdout_file, verbose.stdout_file
      assert_equal direct.stderr_file, verbose.stderr_file
      assert_equal direct.exitstatus, verbose.exitstatus
    end

    def test_verbose_output_is_retrievable_from_the_runtime_log
      redirect("rails", "runner", 'puts "payload"', accelerated: true, env: { "SIDING_LOG" => "1" })

      log = File.join(siding_state_dir.to_s, "siding.log")

      assert File.file?(log), "verbose output went nowhere: no runtime log was written"
      refute_empty File.read(log).strip, "the runtime log exists but the verbose output is not in it"
    end

    def test_verbose_output_reaches_the_terminal_while_the_files_stay_clean
      stdout_path = File.join(scratch_dir, "terminal-out")
      stderr_path = "#{stdout_path}.err"
      command = "exec #{invocation(['rails', 'runner', 'puts "payload"'], true)} " \
                "> #{Shellwords.escape(stdout_path)} 2> #{Shellwords.escape(stderr_path)}"

      session = open_terminal("/bin/sh", "-c", command, env: { "SIDING_LOG" => "1" })
      expect_on(session, /siding/, timeout: 60,
                message: "the developer at the terminal was told nothing")
      # The notice arrives long before the command finishes -- that is what it is for -- so the
      # files are only worth looking at once the command has actually written them.
      wait_for_file(stdout_path, "payload\n")
      session.close

      assert_equal "payload\n", File.read(stdout_path)
      assert_empty File.read(stderr_path), "the terminal got its copy and the file got one too"
    end

    private

    def assert_identical_redirection(*argv)
      accelerated = redirect(*argv, accelerated: true)
      unaccelerated = redirect(*argv, accelerated: false)

      assert_equal unaccelerated.stdout_file, accelerated.stdout_file, "redirected stdout differs"
      assert_equal unaccelerated.stderr_file, accelerated.stderr_file, "redirected stderr differs"
      assert_equal unaccelerated.exitstatus, accelerated.exitstatus
      assert_empty accelerated.shell_stdout, "the tool wrote to a stream the developer redirected away"
      assert_empty accelerated.shell_stderr, "the tool wrote to a stream the developer redirected away"
      accelerated
    end

    def redirect(*argv, accelerated:, env: {})
      stdout_path = File.join(scratch_dir, "out-#{@captures = (@captures || 0) + 1}")
      stderr_path = "#{stdout_path}.err"
      command = "exec #{invocation(argv, accelerated)} " \
                "> #{Shellwords.escape(stdout_path)} 2> #{Shellwords.escape(stderr_path)}"
      shell_stdout, shell_stderr, status = run_shell(command, env: env)

      Capture.new(stdout_file: File.read(stdout_path), stderr_file: File.read(stderr_path),
                  shell_stdout: shell_stdout, shell_stderr: shell_stderr, status: status)
    end

    def through_a_pipe(*argv, accelerated:)
      stdout, _stderr, _status = run_shell("#{invocation(argv, accelerated)} | wc -l")
      stdout.strip + "\n"
    end

    def invocation(argv, accelerated)
      command = accelerated ? [RbConfig.ruby, EXE, *argv] : ["bundle", "exec", *argv]
      Shellwords.join(command)
    end

    def run_shell(command, env: {})
      Open3.capture3(siding_env(env), "/bin/sh", "-c", command, chdir: FIXTURE_APP)
    end

    def scratch_dir
      @scratch_dir ||= Dir.mktmpdir("siding-redirection")
    end

    def wait_for_file(path, contents, timeout: 60)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        return if File.file?(path) && File.read(path) == contents

        sleep 0.05
      end
      flunk "waited #{timeout}s for #{path} to contain #{contents.inspect}"
    end

    def teardown
      super
    ensure
      FileUtils.remove_entry(@scratch_dir) if @scratch_dir && File.directory?(@scratch_dir)
    end
  end
end
