# frozen_string_literal: true

require "json"
require "time"

require_relative "load_manifest"

module Siding
  module Staleness
    FRESH = :fresh
    RELOADABLE = :reloadable
    REBOOT = :reboot

    DEPENDENCIES_CHANGED = :dependencies_changed
    SOURCE_CHANGED = :source_changed
    SOURCE_ADDED_OR_REMOVED = :source_added_or_removed
    ENVIRONMENT_CHANGED = :environment_changed

    MAX_TRIGGER_PATHS = 25

    Verdict = Struct.new(:strategy, :reasons, :trigger_paths, :revision_label, keyword_init: true) do
      def fresh? = strategy == FRESH
      def stale? = !fresh?
      def reloadable? = strategy == RELOADABLE
      def reboot? = strategy == REBOOT

      def resolution
        case strategy
        when FRESH then "fresh"
        when RELOADABLE then "reloaded_in_worker"
        else "rebuild"
        end
      end

      def summary
        return "up to date" if fresh?

        detail = trigger_paths.first
        reason = reasons.first
        detail ? "#{reason}: #{File.basename(detail)}" : reason.to_s
      end
    end

    module_function

    def validate(manifest, env: ENV)
      reasons = []
      triggers = []
      changed_scopes = []

      bundle_token = LoadManifest.token_for(manifest.bundle_files)
      if bundle_token != manifest.bundle_token
        reasons << DEPENDENCIES_CHANGED
        triggers.concat(manifest.bundle_files)
        changed_scopes << LoadManifest::REBOOT
      end

      files = manifest.file_entries.map do |entry|
        stamp = LoadManifest.stamp_for(entry.path)
        unless stamp == stamp_of(entry)
          reasons << SOURCE_CHANGED
          triggers << entry.path
          changed_scopes << entry.scope
        end
        [entry.path, stamp]
      end

      directories = manifest.directory_entries.map do |entry|
        digest = LoadManifest.entry_digest_for(entry.path, recursive: entry.recursive)
        unless digest == entry.entry_digest
          reasons << SOURCE_ADDED_OR_REMOVED
          triggers << entry.path
          changed_scopes << entry.scope
        end
        [entry.path, digest]
      end

      envs = manifest.env_entries.map do |entry|
        digest = LoadManifest.digest_env_value(env[entry.key])
        unless digest == entry.value_digest
          reasons << ENVIRONMENT_CHANGED
          triggers << entry.key
          # Always reboot-class: a value consumed at boot is already inside a constant, and no
          # reloader can reach in there and change it.
          changed_scopes << LoadManifest::REBOOT
        end
        [entry.key, digest]
      end

      Verdict.new(
        strategy: strategy_for(changed_scopes),
        reasons: reasons.uniq,
        trigger_paths: triggers.first(MAX_TRIGGER_PATHS),
        revision_label: LoadManifest.label_for(bundle_token: bundle_token, files: files,
                                               directories: directories, envs: envs)
      )
    end

    def strategy_for(changed_scopes)
      return FRESH if changed_scopes.empty?
      return RELOADABLE if changed_scopes.all? { |scope| scope == LoadManifest::RELOADABLE }

      REBOOT
    end

    def stamp_of(entry) = "#{entry.size}:#{format('%.6f', entry.mtime)}"

    class Events
      LIMIT = 50

      # When the file is rewritten rather than appended to. Rewriting on every record would turn a
      # short append into a full read-modify-write for no benefit.
      COMPACT_AT = LIMIT * 4

      Event = Struct.new(:at, :reason, :trigger_paths, :resolution, :developer_wait,
                         keyword_init: true) do
        def to_h
          {
            "at" => at.iso8601(3),
            "reason" => reason.to_s,
            "trigger_paths" => trigger_paths,
            "resolution" => resolution,
            "developer_wait" => developer_wait
          }
        end

        def self.from_h(hash)
          new(at: Time.iso8601(hash["at"]), reason: hash["reason"],
              trigger_paths: Array(hash["trigger_paths"]), resolution: hash["resolution"],
              developer_wait: hash["developer_wait"])
        rescue ArgumentError, TypeError
          nil
        end
      end

      def initialize(limit: LIMIT, path: nil)
        @limit = limit
        @path = path
        @events = load_recorded
        @mutex = Mutex.new
      end

      def record(verdict, resolution: nil, developer_wait: nil, at: Time.now)
        event = Event.new(at: at, reason: verdict.reasons.first,
                          trigger_paths: verdict.trigger_paths,
                          resolution: resolution || verdict.resolution,
                          developer_wait: developer_wait)
        @mutex.synchronize do
          @events << event
          @events.shift while @events.size > @limit
        end
        persist(event)
        event
      end

      def to_a = @mutex.synchronize { @events.dup }
      def last = @mutex.synchronize { @events.last }
      def size = @mutex.synchronize { @events.size }

      private

      def persist(event)
        return if @path.nil?

        File.open(@path, "a") { |file| file.write("#{JSON.generate(event.to_h)}\n") }
        compact if File.size(@path) > COMPACT_AT * 512
      rescue SystemCallError, JSON::GeneratorError
        nil
      end

      def compact
        lines = File.readlines(@path).last(@limit)
        File.write(@path, lines.join)
      rescue SystemCallError
        nil
      end

      def load_recorded
        return [] if @path.nil? || !File.file?(@path)

        File.readlines(@path).last(@limit).filter_map do |line|
          parsed = JSON.parse(line)
          Event.from_h(parsed) if parsed.is_a?(Hash)
        rescue JSON::ParserError
          nil
        end
      rescue SystemCallError
        []
      end
    end
  end
end
