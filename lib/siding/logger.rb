# frozen_string_literal: true

module Siding
  class Logger
    TERMINAL = "/dev/tty"
    OFF_VALUES = ["0", "false", "no", "off", ""].freeze

    Event = Struct.new(:at, :level, :message, keyword_init: true)

    attr_reader :events

    def initialize(env: ENV, log_path: nil)
      @verbose = self.class.verbose?(env)
      @log_path = log_path
      @events = []
      @terminal = :unopened
    end

    def self.verbose?(env)
      value = env["SIDING_LOG"]
      return false if value.nil?

      !OFF_VALUES.include?(value.strip.downcase)
    end

    def verbose? = @verbose

    def notice(message)
      record(:notice, message)
      write_to_terminal(message)
    end

    def debug(message)
      return unless verbose?

      record(:debug, message)
      write_to_terminal(message) || write_to_log(message)
    end

    def record(level, message)
      @events << Event.new(at: Time.now, level: level, message: message)
    end

    def terminal_available? = !terminal.nil?

    def close
      @terminal.close if @terminal.is_a?(IO) && !@terminal.closed?
    rescue IOError, SystemCallError
      nil
    ensure
      @terminal = nil
    end

    private

    def terminal
      return @terminal unless @terminal == :unopened

      @terminal = begin
        File.open(TERMINAL, "w")
      rescue SystemCallError
        nil
      end
    end

    def write_to_terminal(message)
      io = terminal
      return false unless io

      io.write("#{format_line(message)}\n")
      io.flush
      true
    rescue IOError, SystemCallError
      # The terminal went away mid-run -- the developer closed the window, or the session ended.
      # Not an error worth surfacing; there is no longer anyone to surface it to.
      @terminal = nil
      false
    end

    def write_to_log(message)
      return false unless @log_path

      File.open(@log_path, "a") { |f| f.write("#{format_line(message)}\n") }
      true
    rescue SystemCallError
      false
    end

    def format_line(message) = "[siding] #{message}"
  end
end
