# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "platform"

module Siding
  class Runtime
    DIRECTORY_MODE = 0o700

    NAMESPACE = "siding"

    # Used when XDG_RUNTIME_DIR is unset -- common on macOS, where there is no such convention.
    # `~/.local/state` is the XDG base-directory spec's home for state that should persist between
    # restarts but is not configuration.
    FALLBACK_ROOT = File.join(".local", "state", NAMESPACE)

    class Unavailable < Error
      attr_reader :path

      def initialize(message, path: nil)
        @path = path
        super(message)
      end
    end

    attr_reader :project_key, :root

    def self.for(project_key, env: ENV)
      new(project_key: project_key, root: root_for(env))
    end

    def self.root_for(env)
      xdg = env["XDG_RUNTIME_DIR"]
      return File.join(xdg, NAMESPACE) if xdg && !xdg.empty?

      File.join(Dir.home, FALLBACK_ROOT)
    end

    def initialize(project_key:, root:)
      @project_key = project_key
      @root = root
    end

    def dir = File.join(root, project_key.digest)
    def socket_path = File.join(dir, "sock")
    def lock_path = File.join(dir, "lock")
    def server_info_path = File.join(dir, "server.json")
    def boot_log_path = File.join(dir, "boot.log")
    def events_path = File.join(dir, "events.jsonl")
    def log_path = File.join(dir, "siding.log")

    def server_info
      info = JSON.parse(File.read(server_info_path))
      info.is_a?(Hash) ? info : nil
    rescue SystemCallError, JSON::ParserError
      nil
    end

    def live_server_info
      info = server_info
      return nil if info.nil?

      pid = info["pid"]
      return nil unless pid.is_a?(Integer) && self.class.process_alive?(pid)

      info
    end

    def server_pid = live_server_info&.[]("pid")

    def discard_socket
      File.unlink(socket_path)
      true
    rescue SystemCallError
      false
    end

    def discard_records
      [socket_path, server_info_path].each do |path|
        File.unlink(path)
      rescue SystemCallError
        nil
      end
      true
    end

    def self.process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    rescue SystemCallError
      # Anything else means the question could not be asked, and a live process wrongly called dead
      # would have us boot a second server over a working one.
      true
    end

    def prepare
      check_socket_path_length
      ensure_directory(root)
      ensure_directory(dir)
      self
    end

    def prepared?
      File.directory?(dir) && safe_directory?(dir) && socket_path_within_limit?
    end

    def unavailable_reason
      prepare
      nil
    rescue Unavailable => e
      e.message
    end

    def socket_path_within_limit?
      socket_path.bytesize <= Platform::UNIX_SOCKET_PATH_LIMIT - 1
    end

    private

    def ensure_directory(path)
      FileUtils.mkdir_p(path, mode: DIRECTORY_MODE)
      File.chmod(DIRECTORY_MODE, path)
      verify_ownership(path)
    rescue SystemCallError => e
      raise Unavailable.new("cannot use runtime directory #{path}: #{e.message}", path: path)
    end

    def verify_ownership(path)
      stat = File.stat(path)
      unless stat.uid == Process.uid
        raise Unavailable.new(
          "runtime directory #{path} is owned by uid #{stat.uid}, not #{Process.uid}", path: path
        )
      end

      return if (stat.mode & 0o077).zero?

      raise Unavailable.new(
        "runtime directory #{path} is accessible to other users (mode #{format('%o', stat.mode & 0o777)})",
        path: path
      )
    end

    def safe_directory?(path)
      stat = File.stat(path)
      stat.uid == Process.uid && (stat.mode & 0o077).zero?
    rescue SystemCallError
      false
    end

    def check_socket_path_length
      return if socket_path_within_limit?

      raise Unavailable.new(
        "socket path #{socket_path} is #{socket_path.bytesize} bytes, over the " \
        "#{Platform::UNIX_SOCKET_PATH_LIMIT - 1}-byte limit for Unix domain sockets",
        path: socket_path
      )
    end
  end
end
