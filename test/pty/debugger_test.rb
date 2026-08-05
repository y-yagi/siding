# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

module Siding
  class DebuggerTest < Minitest::Test
    include TestSupport
    include TestSupport::TerminalTests

    PROMPT = /\(rdbg\)/

    def setup
      @script_dir = Dir.mktmpdir("siding-debugger")
      @script = File.join(@script_dir, "breakpoint_script.rb")
      File.write(@script, breakpoint_script)
      super
    end

    def teardown
      super
      FileUtils.remove_entry(@script_dir) if @script_dir && File.directory?(@script_dir)
    end

    def test_a_breakpoint_stops_the_command_and_prompts
      session = open_siding_terminal("rails", "runner", @script)

      expect_on(session, PROMPT, timeout: 90,
                message: "the breakpoint never stopped, or stopped somewhere the developer cannot see")

      finish(session)
    end

    def test_local_state_can_be_inspected_from_the_breakpoint
      session = open_siding_terminal("rails", "runner", @script)
      expect_on(session, PROMPT, timeout: 90)

      session.type("p answer + 1")
      expect_on(session, "42", timeout: 30,
                message: "the debugger could not evaluate anything in the stopped frame")

      finish(session)
    end

    def test_the_command_can_be_stepped_from_the_breakpoint
      session = open_siding_terminal("rails", "runner", @script)
      expect_on(session, PROMPT, timeout: 90)

      session.type("next")
      expect_on(session, PROMPT, timeout: 30, message: "the debugger did not stop again after a step")
      session.type("p stepped")
      expect_on(session, "true", timeout: 30,
                message: "the step did not run the line the program was stopped on")

      finish(session)
    end

    def test_continuing_finishes_the_command_normally
      session = open_siding_terminal("rails", "runner", @script)
      expect_on(session, PROMPT, timeout: 90)

      session.type("continue")
      expect_on(session, "answer=41", timeout: 30,
                message: "the command did not resume after `continue`")
      status = session.wait_for_exit(timeout: 30)

      assert_equal 0, status.exitstatus, "a debugged command reported a failure"
    end

    private

    def breakpoint_script
      <<~RUBY
        answer = 41
        stepped = false
        binding.break
        stepped = true
        puts "answer=\#{answer}"
      RUBY
    end

    def finish(session)
      session.type("continue")
      session.wait_for_exit(timeout: 30)
    end
  end
end
