# frozen_string_literal: true

require_relative "error"

module Siding
  module LifeCycle
    class HookError < Error
      attr_reader :hook_name, :phase, :cause_error

      def initialize(hook_name:, phase:, cause_error:)
        @hook_name = hook_name
        @phase = phase
        @cause_error = cause_error
        super("siding #{phase} hook #{hook_name.inspect} raised #{cause_error.class}: #{cause_error.message}")
      end
    end

    Hook = Struct.new(:name, :block, keyword_init: true)

    SERVER_SIGNALS = %w[TERM INT].freeze

    class << self
      def before_fork(name = nil, &block)
        register(before_fork_hooks, name, block)
      end

      def after_fork(name = nil, &block)
        register(after_fork_hooks, name, block)
      end

      def before_fork_hooks = @before_fork_hooks ||= []

      def after_fork_hooks = @after_fork_hooks ||= []

      def reset!
        @before_fork_hooks = []
        @after_fork_hooks = []
      end

      # For Server

      def prepare_for_fork
        disconnect_database
        run_hooks(before_fork_hooks, :before_fork)
      end

      def remember_signal_handler(signal, previous)
        inherited_signal_handlers[signal] = previous
      end

      def inherited_signal_handlers = @inherited_signal_handlers ||= {}

      # For Worker

      def repair_after_fork
        restore_inherited_signal_handlers
        reseed_random
        reconnect_database
        run_hooks(after_fork_hooks, :after_fork)
      end

      def restore_inherited_signal_handlers
        SERVER_SIGNALS.each do |signal|
          previous = inherited_signal_handlers[signal]
          Signal.trap(signal, previous.nil? ? "DEFAULT" : previous)
        rescue ArgumentError, SystemCallError
          nil
        end
      end

      private

      def register(list, name, block)
        raise ArgumentError, "a fork hook needs a block" if block.nil?

        list << Hook.new(name: name || describe(block), block: block)
        block
      end

      def run_hooks(hooks, phase)
        hooks.each do |hook|
          hook.block.call
        rescue StandardError, ScriptError => e
          raise HookError.new(hook_name: hook.name, phase: phase, cause_error: e)
        end
      end

      def describe(block)
        location = block.source_location
        location ? "#{location[0]}:#{location[1]}" : "anonymous"
      end

      def disconnect_database
        return unless defined?(::ActiveRecord::Base)

        ::ActiveRecord::Base.connection_handler.clear_all_connections!
      rescue StandardError
        nil
      end

      def reconnect_database
        return unless defined?(::ActiveRecord::Base)

        ::ActiveRecord::Base.connection_handler.clear_all_connections!
      rescue StandardError
        nil
      end

      def reseed_random
        srand
      end
    end
  end
end
