# frozen_string_literal: true

require "test_helper"

module Siding
  class InterruptTest < Minitest::Test
    include TestSupport
    include TestSupport::TerminalTests

    PROMPT = /siding-test\$ /
    # waiting".
    PROMPTLY = 2.0

    def test_ctrl_c_ends_the_command_and_returns_the_prompt
      shell = open_shell

      start_a_long_command(shell)
      pressed = now
      shell.interrupt
      expect_on(shell, PROMPT, timeout: 10, message: "the shell never got its prompt back")
      elapsed = now - pressed

      assert_operator elapsed, :<, PROMPTLY,
                      "the prompt came back #{elapsed.round(2)}s after Ctrl-C"
    end

    # `130` is what the shell reports for a command killed by SIGINT, and the first thing a wrong
    # implementation gets right by accident -- a client that exited with 128 + 2 produces the same
    # number here. The loop below is what tells them apart.
    def test_the_shell_reports_the_interrupt_in_its_status_variable
      shell = open_shell

      start_a_long_command(shell)
      shell.interrupt
      expect_on(shell, PROMPT, timeout: 10)

      shell.type("echo status=$?")
      expect_on(shell, "status=130", message: "the shell was told the command exited normally")
    end

    def test_an_interrupted_loop_stops_looping_exactly_as_it_does_without_the_tool
      assert_equal interrupt_a_loop(accelerated: false), interrupt_a_loop(accelerated: true),
                   "an interrupted loop behaved differently through the tool"
    end

    def test_the_warm_application_survives_the_interrupt
      shell = open_shell
      start_a_long_command(shell)
      before = siding_server_pid
      refute_nil before, "no warm application was serving the interrupted command"

      shell.interrupt
      expect_on(shell, PROMPT, timeout: 10)

      shell.type("#{siding_command} rails runner 'puts :again'")
      expect_on(shell, "again", timeout: 30, message: "the next command did not run")

      assert_equal before, siding_server_pid,
                   "the interrupt took the warm application with it, so the next command paid a boot"
    end

    private

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def open_shell
      shell = open_terminal("/bin/bash", "--norc", "--noprofile", "-i",
                            env: { "PS1" => "siding-test$ ", "TERM" => "dumb",
                                   "HISTFILE" => File::NULL, "BASH_SILENCE_DEPRECATION_WARNING" => "1" })
      expect_on(shell, PROMPT, timeout: 15, message: "the test shell never prompted")
      shell
    end

    # Announces itself before sleeping, so the interrupt is sent to a command that is genuinely
    # running rather than to one still booting.
    def start_a_long_command(shell)
      shell.type("#{siding_command} rails runner #{Shellwords.escape(long_running_script)}")
      expect_on(shell, RUNNING, timeout: 60, message: "the command never started")
    end

    # An interactive shell echoes what is typed, so a marker that appears literally in the command
    # line would be matched from the echo -- before the command had started, which is the one thing
    # this test has to be sure of. Assembling it at runtime keeps the echo and the output distinct.
    RUNNING = "running-now"

    def long_running_script
      'STDOUT.sync = true; puts %w[running now].join("-"); sleep 30'
    end

    def interrupt_a_loop(accelerated:)
      shell = open_shell
      command = accelerated ? siding_command : "bundle exec"
      shell.type("for i in 1 2 3; do #{command} rails runner " \
                 "#{Shellwords.escape(long_running_script)}; done")

      expect_on(shell, RUNNING, timeout: 60, message: "the loop never entered its first command")
      shell.interrupt
      # Nothing is appended after the loop to signal that it is over: a shell that abandons the loop
      # abandons the rest of the command line with it, so the prompt is the only signal there is.
      expect_on(shell, PROMPT, timeout: 30, message: "the shell never got its prompt back")
      # Long enough for a further iteration to announce itself if the shell started one, so this
      # counts what the shell did rather than what it had got around to.
      shell.refute_appears(RUNNING, within: 2)

      # The count of iterations that started is the whole observation: one if the shell abandoned the
      # loop, three if it treated the interrupt as an ordinary non-zero exit.
      { iterations: shell.screen.scan(RUNNING).size }
    end

    def siding_command
      Shellwords.join([RbConfig.ruby, EXE])
    end
  end
end
