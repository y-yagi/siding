# frozen_string_literal: true

require "test_helper"

module Siding
  class BootFailureTest < Minitest::Test
    include TestSupport
    include FixtureEdits

    MESSAGE = "fixture initializer refuses to boot"

    def test_the_boot_error_reaches_the_developer_and_nothing_reusable_is_kept
      break_the_application

      result = siding_invoke("rails", "runner", "print 'unreachable'")

      refute_equal 0, result.exitstatus, "a failed boot reported success"
      assert_includes result.stderr, MESSAGE,
                      "the developer was not told why their application did not boot"
      # Verbatim means verbatim: the class and the raising line, in Ruby's own format, not a summary.
      assert_includes result.stderr, "RuntimeError"
      assert_includes result.stderr, "config/initializers/refuses_to_boot.rb"
      assert_empty result.stdout, "the command ran despite the application never booting"

      # Nothing was kept that a later invocation could be served from. A half-booted process retained
      # here is how a broken application becomes a broken application that also serves stale code.
      refute warm_application?, "a warm application was kept after a boot that failed"
    end

    def test_the_failure_is_indistinguishable_from_an_unaccelerated_one
      break_the_application

      accelerated = siding_invoke("rails", "runner", "print 'unreachable'")
      unaccelerated = unaccelerated_invoke("rails", "runner", "print 'unreachable'")

      assert_equal unaccelerated.stderr, accelerated.stderr,
                   "the tool added to, or subtracted from, the application's own boot error"
      assert_equal unaccelerated.stdout, accelerated.stdout
      assert_equal unaccelerated.exitstatus, accelerated.exitstatus
    end

    def test_the_servers_boot_output_is_kept_for_doctor_to_report
      break_the_application

      siding_invoke("rails", "runner", "print 'unreachable'")

      dir = siding_state_dir
      refute_nil dir, "the tool left no runtime directory at all"
      log = File.join(dir, "boot.log")

      assert File.file?(log), "the failed boot was not recorded anywhere"
      assert_includes File.read(log), MESSAGE
    end

    def test_fixing_the_application_is_the_whole_recovery
      break_the_application
      siding_invoke("rails", "runner", "print 'unreachable'")

      restore_fixtures

      result = siding_invoke("rails", "runner", "print 'recovered'")

      assert_equal 0, result.exitstatus, result.stderr
      assert_equal "recovered", result.stdout.split.last
      assert warm_application?, "the recovered application was not warmed up"
    end

    private

    def break_the_application
      edit_fixture("config/initializers/refuses_to_boot.rb") do
        <<~RUBY
          # Added by #{self.class.name}; removed again in teardown.
          raise #{MESSAGE.inspect}
        RUBY
      end
    end
  end
end
