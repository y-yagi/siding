# frozen_string_literal: true

require "test_helper"

module Siding
  class LifeCycleSignalsTest < Minitest::Test
    def setup
      @previous = LifeCycle::SERVER_SIGNALS.to_h { |signal| [signal, Signal.trap(signal, "DEFAULT")] }
    end

    def teardown
      @previous.each { |signal, handler| Signal.trap(signal, handler || "DEFAULT") }
      super
    end

    def test_it_restores_the_handler_that_was_in_place_before_the_server_installed_its_own
      application_handler = proc { nil }
      LifeCycle::SERVER_SIGNALS.each do |signal|
        # What an application's own initializer would have left behind, before the server trapped
        # over it.
        Signal.trap(signal, application_handler)
        LifeCycle.remember_signal_handler(signal, Signal.trap(signal) { nil })
      end

      LifeCycle.restore_inherited_signal_handlers

      LifeCycle::SERVER_SIGNALS.each do |signal|
        assert_equal application_handler, Signal.trap(signal, "DEFAULT"),
                     "#{signal} was not returned to the application's own handler"
      end
    end

    def test_it_restores_the_default_disposition_when_nothing_had_trapped_the_signal
      LifeCycle::SERVER_SIGNALS.each do |signal|
        LifeCycle.remember_signal_handler(signal, Signal.trap(signal) { nil })
      end

      LifeCycle.restore_inherited_signal_handlers

      LifeCycle::SERVER_SIGNALS.each do |signal|
        assert_equal "DEFAULT", Signal.trap(signal, "DEFAULT"),
                     "#{signal} would still be swallowed by an inherited handler"
      end
    end

    def test_it_leaves_the_process_alone_when_there_is_nothing_remembered
      LifeCycle.instance_variable_set(:@inherited_signal_handlers, nil)
      LifeCycle::SERVER_SIGNALS.each { |signal| Signal.trap(signal, "DEFAULT") }

      LifeCycle.restore_inherited_signal_handlers

      LifeCycle::SERVER_SIGNALS.each do |signal|
        assert_equal "DEFAULT", Signal.trap(signal, "DEFAULT")
      end
    end
  end
end
