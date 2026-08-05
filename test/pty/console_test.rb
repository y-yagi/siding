# frozen_string_literal: true

require "test_helper"

module Siding
  class ConsoleTest < Minitest::Test
    include TestSupport
    include TestSupport::TerminalTests

    # IRB's own prompt, in either of the two shapes Rails leaves it: the application-named one and
    # the bare IRB one a fallback would produce.
    PROMPT = /(\(dev\)|irb\(main\)).*[>*]/

    def test_the_console_prompts_and_evaluates_what_is_typed
      console = open_siding_terminal("rails", "console")

      expect_on(console, PROMPT, message: "the console never prompted, so nothing could be typed")

      console.type('puts "sum=#{2 + 2}"')
      expect_on(console, "sum=4", message: "what was typed was not evaluated")
      expect_on(console, PROMPT, message: "the console did not prompt again after evaluating")

      leave(console)
    end

    def test_the_console_has_the_application_loaded
      console = open_siding_terminal("rails", "console")
      expect_on(console, PROMPT)

      console.type("puts FixtureMarker::MARKER")
      expect_on(console, "initializer-v1", message: "the application was not loaded in the console")

      leave(console)
    end

    def test_the_console_sees_its_streams_as_a_terminal
      console = open_siding_terminal("rails", "console")
      expect_on(console, PROMPT)

      console.type("puts [$stdin.tty?, $stdout.tty?, $stderr.tty?].inspect")
      expect_on(console, "[true, true, true]",
                message: "the console does not believe it is attached to a terminal")

      leave(console)
    end

    def test_a_typed_character_can_be_erased_before_the_line_is_submitted
      console = open_siding_terminal("rails", "console")
      expect_on(console, PROMPT)

      console.write("puts 41X")
      console.write(TestSupport::TerminalSession::BACKSPACE)
      console.write("\n")

      expect_on(console, /^41\r?$/, message: "the erased character was submitted anyway")
      assert console.refute_appears("NameError", within: 1),
             "the backspace reached IRB as a literal character, so line editing is not working"

      leave(console)
    end

    def test_the_console_sees_the_real_window_size
      console = open_siding_terminal("rails", "console", rows: 30, columns: 100)
      expect_on(console, PROMPT)

      console.type("require 'io/console'; puts $stdout.winsize.inspect")
      expect_on(console, "[30, 100]", message: "the console was given a window size of its own")

      leave(console)
    end

    def test_leaving_the_console_ends_the_invocation_cleanly
      console = open_siding_terminal("rails", "console")
      expect_on(console, PROMPT)

      console.type("exit")
      status = console.wait_for_exit(timeout: 30)

      refute_nil status, "the console did not exit after `exit` was typed"
      assert_equal 0, status.exitstatus, "leaving the console reported a failure"
    end

    private

    def leave(console)
      console.type("exit")
      console.wait_for_exit(timeout: 30)
    end
  end
end
