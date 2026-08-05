# frozen_string_literal: true

require "pty"
require "io/console"
require "shellwords"

module Siding
  module TestSupport
    class TerminalSession
      DEFAULT_TIMEOUT = 60
      CHUNK = 4096

      ESCAPES = /
        \e\[[0-9;?]*[ -\/]*[@-~]   # CSI: colours, cursor moves, erases, queries
        | \e\][^\a\e]*(?:\a|\e\\)  # OSC: title changes and friends, to BEL or ST
        | \e[@-Z\\-_]              # the two-character escapes
        | \a                       # the bell a completion attempt rings
      /x.freeze

      PARTIAL_ESCAPE = /\e(?:\[[0-9;?]*[ -\/]*|\][^\a\e]*)?\z/.freeze
      PARTIAL_LIMIT = 64

      INTERRUPT = "\x03"
      SUSPEND = "\x1a"
      BACKSPACE = "\x7f"

      class Timeout < StandardError; end

      attr_reader :pid, :transcript

      def initialize(command:, env: {}, chdir: nil, rows: 24, columns: 80)
        @transcript = +"".b
        @visible = +"".b
        @pending = +"".b
        @cursor = 0
        @eof = false
        options = {}
        options[:chdir] = chdir if chdir
        @master, @writer, @pid = PTY.spawn(env, *command, **options)
        resize(rows: rows, columns: columns)
      end

      def expect(pattern, timeout: DEFAULT_TIMEOUT)
        pattern = Regexp.new(Regexp.escape(pattern)) if pattern.is_a?(String)
        deadline = now + timeout

        loop do
          match = pattern.match(unmatched)
          if match
            @cursor += match.end(0)
            return match
          end
          remaining = deadline - now
          raise Timeout, timeout_message(pattern, timeout) if remaining <= 0 || @eof

          read_more(remaining)
        end
      end

      def refute_appears(pattern, within:)
        pattern = Regexp.new(Regexp.escape(pattern)) if pattern.is_a?(String)
        deadline = now + within
        read_more(deadline - now) while now < deadline && !pattern.match?(unmatched)
        !pattern.match?(unmatched)
      end

      def type(text) = write("#{text}\n")

      def write(raw)
        @writer.write(raw)
        @writer.flush
        self
      rescue Errno::EIO, IOError
        self
      end

      def interrupt = write(INTERRUPT)

      def resize(rows:, columns:)
        @master.winsize = [rows, columns]
        self
      rescue Errno::EINVAL, Errno::ENOTTY
        self
      end

      def winsize = @master.winsize

      def wait_for_exit(timeout: DEFAULT_TIMEOUT)
        deadline = now + timeout
        read_more(deadline - now) while now < deadline && !@eof
        _, status = Process.waitpid2(@pid, @eof ? 0 : Process::WNOHANG)
        @status = status if status
        @status
      rescue Errno::ECHILD
        @status
      end

      def close
        Process.kill("KILL", @pid) if running?
        wait_for_exit(timeout: 5)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      ensure
        [@writer, @master].each { |io| io.close unless io.nil? || io.closed? }
      end

      def running?
        Process.waitpid(@pid, Process::WNOHANG).nil?
      rescue Errno::ECHILD
        false
      end

      def screen = @visible.gsub("\r\n", "\n")

      private

      def unmatched = @visible.byteslice(@cursor..) || ""

      def read_more(timeout)
        return false if @eof || timeout <= 0
        return false unless @master.wait_readable([timeout, 0.5].min)

        append(@master.readpartial(CHUNK))
        true
      rescue Errno::EIO, EOFError
        # How a pty reports that the last process holding the slave has exited.
        @eof = true
        @visible << @pending
        @pending = +"".b
        false
      end

      def append(chunk)
        @transcript << chunk
        stripped = (@pending + chunk.b).gsub(ESCAPES, "")
        partial = PARTIAL_ESCAPE.match(stripped)
        if partial && partial[0].bytesize <= PARTIAL_LIMIT
          @visible << stripped[0...partial.begin(0)]
          @pending = +partial[0]
        else
          @visible << stripped
          @pending = +"".b
        end
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def timeout_message(pattern, timeout)
        <<~MESSAGE
          waited #{timeout}s for #{pattern.inspect} on the terminal#{' (the process has exited)' if @eof}.

          What the developer would have seen:
          #{screen.empty? ? '(nothing at all)' : screen}
        MESSAGE
      end
    end

    module TerminalTests
      def open_terminal(*command, env: {}, chdir: FIXTURE_APP, rows: 24, columns: 80)
        session = TerminalSession.new(command: command, env: siding_env(env), chdir: chdir,
                                      rows: rows, columns: columns)
        track_pid(session.pid)
        (@terminal_sessions ||= []) << session
        session
      end

      def open_siding_terminal(*argv, **options)
        open_terminal(RbConfig.ruby, EXE, *argv, **options)
      end

      def open_unaccelerated_terminal(*argv, **options)
        open_terminal("bundle", "exec", *argv, **options)
      end

      def expect_on(session, pattern, timeout: 60, message: nil)
        session.expect(pattern, timeout: timeout)
      rescue TerminalSession::Timeout => e
        flunk [message, e.message].compact.join("\n\n")
      end

      def teardown
        @terminal_sessions&.each(&:close)
        super
      end
    end
  end
end
