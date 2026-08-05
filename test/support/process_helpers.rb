# frozen_string_literal: true

module Siding
  module ProcessHelpers
    def tracked_pids
      @tracked_pids ||= []
    end

    def track_pid(pid)
      tracked_pids << pid
      pid
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def recorded_pids(runtime_dir)
      return [] unless runtime_dir && File.directory?(runtime_dir)

      Dir.glob(File.join(runtime_dir, "**", "*")).filter_map do |path|
        next unless File.file?(path)

        content = File.read(path, 4096)
        next if content.nil?

        content[/^\s*"?pid"?\s*[:=]\s*(\d+)/, 1]&.to_i || content[/\A\s*(\d+)\s*\z/, 1]&.to_i
      end.uniq
    end

    def assert_no_surviving_processes(runtime_dir: nil, timeout: 5.0)
      candidates = (tracked_pids + recorded_pids(runtime_dir)).uniq
      return if candidates.empty?

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      survivors = []
      loop do
        survivors = candidates.select { |pid| alive?(pid) }
        break if survivors.empty?
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end

      assert_empty survivors, <<~MESSAGE
        #{survivors.size} process(es) belonging to the tool survived the test.
        Surviving pids: #{survivors.join(", ")}
        #{survivors.map { |pid| "  #{pid}: #{process_description(pid)}" }.join("\n")}
      MESSAGE
    end

    def process_description(pid)
      out = IO.popen(["ps", "-o", "command=", "-p", pid.to_s], err: IO::NULL, &:read)
      out.to_s.strip.empty? ? "(no description available)" : out.strip
    rescue SystemCallError
      "(ps unavailable)"
    end

    def reap_tracked_processes
      tracked_pids.each do |pid|
        next unless alive?(pid)

        begin
          Process.kill("TERM", pid)
        rescue SystemCallError
          next
        end
      end
      tracked_pids.each do |pid|
        Process.wait(pid)
      rescue Errno::ECHILD, Errno::ESRCH
        next
      end
      tracked_pids.clear
    end
  end
end
