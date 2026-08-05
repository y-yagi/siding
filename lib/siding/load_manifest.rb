# frozen_string_literal: true

require "digest"
require "set"

require_relative "boot_component"

module Siding
  class LoadManifest
    RELOADABLE = :reloadable
    REBOOT = :reboot

    FileEntry = Struct.new(:path, :size, :mtime, :scope)
    DirectoryEntry = Struct.new(:path, :entry_digest, :recursive, :scope)
    EnvEntry = Struct.new(:key, :value_digest)

    EXCLUDED_SUBDIRECTORIES = %w[tmp log storage node_modules .git vendor/bundle].freeze

    INITIALIZER_DIRECTORY = File.join("config", "initializers")

    attr_reader :app_root, :file_entries, :directory_entries, :env_entries, :bundle_token, :bundle_files, :bundle_path, :captured_at

    class << self
      def around_boot(app_root:)
        env = EnvProbe.start
        loads = LoadProbe.start
        before = $LOADED_FEATURES.dup
        yield

        build(app_root: app_root, loaded: ($LOADED_FEATURES - before) + loads.finish, env_reads: env.finish)
      ensure
        env&.stop
        loads&.stop
      end

      def build(app_root:, loaded:, env_reads: {})
        new(app_root: app_root, loaded: loaded, env_reads: env_reads)
      end

      def label_for(bundle_token:, files:, directories:, envs:)
        digest = Digest::SHA256.new
        digest << "bundle\0#{bundle_token}\n"
        files.each { |path, stamp| digest << "file\0#{path}\0#{stamp}\n" }
        directories.each { |path, entry_digest| digest << "dir\0#{path}\0#{entry_digest}\n" }
        envs.each { |key, value| digest << "env\0#{key}\0#{value.nil? ? "\1" : value}\n" }
        digest.hexdigest[0, 12]
      end

      def stamp_for(path)
        stat = File.stat(path)
        "#{stat.size}:#{format('%.6f', stat.mtime.to_f)}"
      rescue SystemCallError
        # A loaded file that no longer exists is a change like any other, and one that must not be
        # mistaken for "unchanged" by a comparison against nil on both sides.
        "missing"
      end

      def entry_digest_for(path, recursive:)
        names = child_names(path, recursive: recursive)
        return "missing" if names.nil?

        Digest::SHA256.hexdigest(names.sort.join("\n"))
      end

      def child_names(path, recursive:)
        recursive ? Dir.glob("**/*", base: path).sort : Dir.children(path).sort
      rescue SystemCallError
        nil
      end

      def digest_env_value(value)
        Digest::SHA256.hexdigest(value.nil? ? "0" : "1\0#{value}")
      end

      def token_for(paths)
        digest = Digest::SHA256.new
        paths.each do |path|
          digest << path << "\0"
          digest << (File.file?(path) ? File.read(path) : "")
        end
        digest.hexdigest[0, 16]
      rescue SystemCallError
        nil
      end
    end

    def initialize(app_root:, loaded:, env_reads: {})
      @app_root = realpath(app_root)
      @captured_at = Time.now
      @bundle_path = discover_bundle_path
      @bundle_files = discover_bundle_files
      @bundle_token = self.class.token_for(@bundle_files)
      @file_entries = capture_file_entries(loaded)
      @directory_entries = capture_directory_entries
      @env_entries = capture_env_entries(env_reads)
    end

    def revision_label
      @revision_label ||= self.class.label_for(
        bundle_token: bundle_token,
        files: file_entries.map { |entry| [entry.path, "#{entry.size}:#{format('%.6f', entry.mtime)}"] },
        directories: directory_entries.map { |entry| [entry.path, entry.entry_digest] },
        envs: env_entries.map { |entry| [entry.key, entry.value_digest] }
      )
    end

    def to_s = "#{file_entries.size} files, #{directory_entries.size} directories, " \
               "#{env_entries.size} environment variables"

    private

    def realpath(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
    end

    def capture_file_entries(loaded)
      local_roots = local_gem_roots
      reloadable = reloadable_paths

      entries = (loaded + configuration_files).uniq.filter_map do |path|
        next unless watchable?(path, local_roots)

        stat = file_stat(path)
        next if stat.nil?

        FileEntry.new(path, stat.size, stat.mtime.to_f, reloadable.include?(path) ? RELOADABLE : REBOOT)
      end

      (entries + boot_file_entries).uniq(&:path)
    end

    def boot_file_entries
      BootComponent.paths.filter_map do |path|
        stat = file_stat(path)
        next if stat.nil? || !stat.file?

        FileEntry.new(path, stat.size, stat.mtime.to_f, REBOOT)
      end
    end

    def configuration_files
      Dir.glob(File.join(app_root, "config", "*")).select { |path| File.file?(path) }
    rescue SystemCallError
      []
    end

    def watchable?(path, local_roots)
      return true if under_any?(path, local_roots)
      return false unless under?(path, app_root)
      return false if bundle_path && under?(path, bundle_path)

      excluded_directories.none? { |directory| under?(path, directory) }
    end

    def excluded_directories
      @excluded_directories ||= EXCLUDED_SUBDIRECTORIES.map { |name| File.join(app_root, name) }
    end

    def file_stat(path)
      File.stat(path)
    rescue SystemCallError
      nil
    end

    def capture_directory_entries
      local_roots = local_gem_roots

      entries = autoload_roots.filter_map do |directory, reloadable|
        next unless watchable?(directory, local_roots)

        DirectoryEntry.new(directory, self.class.entry_digest_for(directory, recursive: true), true, reloadable ? RELOADABLE : REBOOT)
      end

      initializers = File.join(app_root, INITIALIZER_DIRECTORY)
      if File.directory?(initializers)
        entries << DirectoryEntry.new(initializers, self.class.entry_digest_for(initializers, recursive: true), true, REBOOT)
      end

      entries.concat(boot_directory_entries)
      entries.uniq(&:path)
    end

    def boot_directory_entries
      BootComponent.paths.filter_map do |path|
        next unless File.directory?(path)

        DirectoryEntry.new(path, self.class.entry_digest_for(path, recursive: true), true, REBOOT)
      end
    end

    def reloadable_paths
      loaders = reloading_loaders
      return Set.new if loaders.empty?

      loaders.each_with_object(Set.new) do |loader, paths|
        loader.all_expected_cpaths.each_key { |path| paths << path }
      end
    rescue StandardError, NotImplementedError
      Set.new
    end

    def reloading_loaders
      return [] unless rails_application?
      return [] unless ::Rails.application.config.respond_to?(:enable_reloading)
      return [] unless ::Rails.application.config.enable_reloading

      ::Rails.autoloaders.to_a.select { |loader| loader.reloading_enabled? }
    rescue StandardError
      []
    end

    def autoload_roots
      return [] unless rails_application?

      roots = {}
      ::Rails.autoloaders.to_a.each do |loader|
        reloadable = loader.reloading_enabled?
        loader.dirs.each { |dir| roots[dir] = reloadable if File.directory?(dir) }
      end
      roots.to_a
    rescue StandardError
      []
    end

    def rails_application?
      defined?(::Rails) && ::Rails.respond_to?(:application) && !::Rails.application.nil?
    end

    def discover_bundle_path
      return nil unless defined?(::Bundler)

      realpath(::Bundler.bundle_path.to_s)
    rescue StandardError
      nil
    end

    def discover_bundle_files
      gemfile =
        begin
          defined?(::Bundler) ? ::Bundler.default_gemfile.to_s : File.join(app_root, "Gemfile")
        rescue StandardError
          File.join(app_root, "Gemfile")
        end

      [gemfile, "#{gemfile}.lock"]
    end

    def local_gem_roots
      @local_gem_roots ||= begin
        if defined?(::Bundler)
          ::Bundler.load.specs.filter_map { |spec| spec.full_gem_path if local_source?(spec.source) }
        else
          []
        end
      rescue StandardError
        []
      end
    end

    def local_source?(source)
      defined?(::Bundler::Source::Path) && source.is_a?(::Bundler::Source::Path)
    end

    def capture_env_entries(env_reads)
      env_reads.map { |key, value| EnvEntry.new(key, self.class.digest_env_value(value)) }
    end

    def under?(path, root)
      return false if root.nil? || root.empty?

      path == root || path.start_with?("#{root}#{File::SEPARATOR}")
    end

    def under_any?(path, roots) = roots.any? { |root| under?(path, root) }

    # Watches `Kernel#load` for the duration of a boot.
    #
    # `$LOADED_FEATURES` only knows about `require`. Rails runs `config/initializers/*.rb` and
    # `config/routes.rb` through `load`, precisely so they can be re-run, and those files are
    # therefore invisible to a manifest built from the feature list alone -- an initializer could
    # be edited all day without the tool noticing. Observing the interpreter is the same answer the
    # rest of this class gives: what the boot actually loaded is what gets watched.
    module LoadProbe
      class << self
        def start
          install
          @paths = []
          @recording = true
          self
        end

        def stop
          @recording = false
          self
        end

        def finish
          stop
          @paths
        end

        def note(path)
          return unless @recording
          return unless path.is_a?(String) || path.respond_to?(:to_path)

          @paths << File.expand_path(path.to_s)
        rescue StandardError
          nil
        end

        private

        # Prepended to `Kernel` once, and guarded by a flag rather than removed -- for the same
        # reason as the environment probe, and with the same cost when idle.
        def install
          return if @installed

          ::Kernel.prepend(Interceptor)
          @installed = true
        end
      end

      module Interceptor
        def load(path, *args)
          LoadProbe.note(path)
          super
        end
      end
    end

    module EnvProbe
      IGNORED_PREFIXES = %w[SIDING_ BUNDLE_ BUNDLER_ RUBY GEM_ XDG_ LC_].freeze

      IGNORED_KEYS = %w[
        RAILS_ENV RACK_ENV RAILS_GROUPS PATH PWD OLDPWD SHLVL _ LANG LANGUAGE
        TERM TERM_PROGRAM TERM_PROGRAM_VERSION TERM_SESSION_ID COLORTERM COLUMNS LINES
        SSH_AUTH_SOCK SSH_CLIENT SSH_CONNECTION SSH_TTY TMUX TMUX_PANE STY WINDOWID DISPLAY
        DBUS_SESSION_BUS_ADDRESS
        SOURCE_DATE_EPOCH DEBUG_RESOLVER DEBUG_RESOLVER_TREE SKIP_BUNDLER_CHECKSUM PAGER RI_PAGER
      ].to_set.freeze

      class << self
        def start
          install
          @reads = []
          @seen = Set.new
          @writes = Set.new
          @recording = true
          self
        end

        def stop
          @recording = false
          self
        end

        def finish
          stop
          keys = @reads - @writes.to_a
          keys.to_h { |key| [key, raw(key)] }
        end

        def recording? = @recording

        def around_write(key)
          return yield unless recording?

          before = raw(key)
          result = yield
          note_write(key) unless raw(key) == before
          result
        end

        def around_bulk_write
          return yield unless recording?

          before = ENV.to_hash
          result = yield
          after = ENV.to_hash
          (before.keys | after.keys).each do |key|
            note_write(key) unless before[key] == after[key]
          end
          result
        end

        def note_write(key)
          @writes << key
        end

        def note_read(key)
          return unless recording?
          return unless key.is_a?(String)
          return if ignored?(key)
          return unless @seen.add?(key)

          @reads << key
        end

        def ignored?(key)
          IGNORED_KEYS.include?(key) || IGNORED_PREFIXES.any? { |prefix| key.start_with?(prefix) }
        end

        private

        def install
          return if @installed

          @raw = ENV.method(:[])
          ENV.singleton_class.prepend(Interceptor)
          @installed = true
        end

        def raw(key) = @raw.call(key)
      end

      module Interceptor
        def [](key)
          EnvProbe.note_read(key)
          super
        end

        def fetch(key, *args, &block)
          EnvProbe.note_read(key)
          super
        end

        def key?(key)
          EnvProbe.note_read(key)
          super
        end
        alias has_key? key?
        alias include? key?
        alias member? key?

        def dig(key, *args)
          EnvProbe.note_read(key)
          super
        end

        def values_at(*keys)
          keys.each { |key| EnvProbe.note_read(key) }
          super
        end

        def slice(*keys)
          keys.each { |key| EnvProbe.note_read(key) }
          super
        end

        def []=(key, value)
          EnvProbe.around_write(key) { super }
        end
        alias store []=

        def delete(key, &block)
          EnvProbe.around_write(key) { super }
        end

        def update(*others, &block)
          EnvProbe.around_bulk_write { super }
        end
        alias merge! update

        def replace(other)
          EnvProbe.around_bulk_write { super }
        end

        def clear
          EnvProbe.around_bulk_write { super }
        end
      end
    end
  end
end
