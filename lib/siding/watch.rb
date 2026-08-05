# frozen_string_literal: true
#
require "watchcat"

module Siding
  class Watch
    EVENTS = :events
    POLL = :poll

    RootEntry = Struct.new(:path, :recursive)

    class << self
      def mode_from(env, logger: nil)
        value = env["SIDING_WATCH"]
        return POLL if value == "poll"
        return EVENTS if value.nil? || value == "events"

        logger&.debug("restarter watch: unrecognized SIDING_WATCH=#{value.inspect}; using events")
        EVENTS
      end

      def roots_for(manifest)
        recursive_paths = manifest.directory_entries.map(&:path).uniq

        file_dirs = manifest.file_entries.map { |entry| File.dirname(entry.path) }
        bundle_dirs = manifest.bundle_files.map { |path| File.dirname(path) }
        non_recursive_paths = (file_dirs + bundle_dirs).uniq.reject do |path|
          under_recursive_root?(path, recursive_paths)
        end

        entries = recursive_paths.map { |path| RootEntry.new(path, true) } + non_recursive_paths.map { |path| RootEntry.new(path, false) }
        entries.uniq(&:path).select { |entry| File.directory?(entry.path) }
      end

      def start(manifest:, env:, logger:, &on_change)
        mode = mode_from(env, logger: logger)
        entries = roots_for(manifest)
        return nil if entries.empty?

        begin
          executor = build_executor(entries, on_change, force_polling: mode == POLL)
        rescue StandardError => e
          logger.debug("restarter watch: could not start watchcat (#{e.class}: #{e.message}); using poll")
          return Watcher.unavailable("#{e.class}: #{e.message}")
        end

        Watcher.active(executor, mode)
      end

      private

      def under_recursive_root?(path, recursive_paths)
        recursive_paths.any? { |root| path == root || path.start_with?("#{root}#{File::SEPARATOR}") }
      end

      def build_executor(entries, on_change, force_polling:)
        recursive = entries.select(&:recursive).map(&:path)
        non_recursive = entries.reject(&:recursive).map(&:path)
        callback = proc { on_change.call }

        filters = { ignore_access: true }

        if recursive.any?
          executor = Watchcat.watch(recursive, recursive: true, force_polling: force_polling, filters: filters, &callback)
          # `force_polling` is fixed at construction and applies to the whole executor, so a
          # second call to add the non-recursive roots inherits it -- there is no per-path knob.
          executor.watch(non_recursive, recursive: false) if non_recursive.any?
        else
          executor = Watchcat.watch(non_recursive, recursive: false, force_polling: force_polling, filters: filters, &callback)
        end

        executor
      end
    end

    class Watcher
      def self.active(executor, mode)
        label = mode == POLL ? "poll (watchcat)" : "events (watchcat)"
        new(executor: executor, label: label, attempted: true)
      end

      def self.unavailable(reason) = new(executor: nil, label: "poll -- watchcat could not start: #{reason}", attempted: false)

      def initialize(executor:, label:, attempted:)
        @executor = executor
        @label = label
        @attempted = attempted
      end

      def watching?
        @attempted && alive?
      end

      def mode_label
        return @label if @attempted && alive?
        return @label unless @attempted

        "poll -- watchcat watcher thread died"
      end

      def stop
        @executor&.stop
      end

      private

      def alive?
        return true if @executor.nil?
        @executor.alive?
      rescue StandardError
        true
      end
    end
  end
end
