# frozen_string_literal: true

require "test_helper"

module Siding
  class ResizeTest < Minitest::Test
    include TestSupport
    include TestSupport::TerminalTests

    def test_a_command_starts_with_the_terminals_own_window_size
      session = open_siding_terminal("rails", "runner", size_script, rows: 40, columns: 132)

      expect_on(session, "size=[40, 132]",
                message: "the command was given a window size that is not this terminal's")
      session.wait_for_exit(timeout: 30)
    end

    def test_a_resize_during_the_command_is_delivered_with_the_new_size
      session = open_siding_terminal("rails", "runner", resize_script, rows: 24, columns: 80)
      expect_on(session, "ready", timeout: 60, message: "the command never started")

      session.resize(rows: 50, columns: 120)

      expect_on(session, "resized=[50, 120]", timeout: 10,
                message: "SIGWINCH did not reach the command, so it kept the size it started with")
      status = session.wait_for_exit(timeout: 30)

      assert_equal 0, status.exitstatus
    end

    def test_the_resize_is_observed_exactly_as_it_is_without_the_tool
      accelerated = observe_a_resize(:open_siding_terminal)
      unaccelerated = observe_a_resize(:open_unaccelerated_terminal)

      assert_equal unaccelerated, accelerated,
                   "the resize was observed differently through the tool"
    end

    private

    def observe_a_resize(opener)
      session = public_send(opener, "rails", "runner", resize_script, rows: 24, columns: 80)
      expect_on(session, "ready", timeout: 60, message: "the command never started")
      session.resize(rows: 50, columns: 120)
      match = expect_on(session, /resized=\[[0-9]+, [0-9]+\]/, timeout: 10,
                        message: "the resize was never observed")
      session.wait_for_exit(timeout: 30)
      match[0]
    end

    def size_script
      <<~RUBY
        require "io/console"
        puts "size=\#{$stdout.winsize.inspect}"
      RUBY
    end

    def resize_script
      <<~RUBY
        require "io/console"
        STDOUT.sync = true
        resized = false
        trap("WINCH") { resized = true }
        puts "ready"
        100.times { break if resized; sleep 0.1 }
        puts(resized ? "resized=\#{$stdout.winsize.inspect}" : "no-signal")
      RUBY
    end
  end
end
