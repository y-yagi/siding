# frozen_string_literal: true

require "test_helper"

module Siding
  class LifeCycleTest < Minitest::Test
    include TestSupport

    LINGER = 30
    IDLE_TIMEOUT = 3

    def test_a_client_killed_uncatchably_leaves_no_worker_behind
      warm_up
      worker = start_lingering_command

      Process.kill("KILL", worker.client_pid)
      Process.wait(worker.client_pid)

      assert wait_until { !alive?(worker.pid) },
             "the worker outlived the client that was holding it"
      # The point of the guarantee: the *next* command works. A tool that cleaned up but needed a
      # manual step afterwards would fail the requirement just as surely.
      assert_equal "ok", siding_invoke("rails", "runner", "print 'ok'").stdout.split.last
    end

    def test_children_of_a_killed_command_are_not_orphaned
      warm_up
      worker = start_lingering_command(spawn_child: true)
      child = wait_for_pid(worker.child_path)

      refute_nil child, "the command never started its child"

      Process.kill("KILL", worker.client_pid)
      Process.wait(worker.client_pid)

      assert wait_until { !alive?(worker.pid) }, "the worker survived its client"
      assert wait_until { !alive?(child) },
             "the command's child was left running with nobody supervising it"
    end

    def test_a_socket_with_no_listener_behind_it_is_recovered_without_a_manual_step
      first = warm_up

      Process.kill("KILL", first)
      assert wait_until { !alive?(first) }

      assert File.socket?(File.join(siding_state_dir, "sock")),
             "this test is only meaningful while the dead server's socket file is still there"

      result = siding_invoke("rails", "runner", "print 'ok'")

      assert_equal 0, result.exitstatus, result.stderr
      assert_equal "ok", result.stdout.split.last
      refute_equal first, siding_server_pid, "the dead server appears to be serving commands"
    end

    def test_a_server_leaves_after_its_idle_timeout
      pid = warm_up(env: { "SIDING_IDLE_TIMEOUT" => IDLE_TIMEOUT.to_s })

      assert wait_until(IDLE_TIMEOUT + 15) { !alive?(pid) },
             "the server was still resident well past its idle timeout"
      assert_nil siding_server_info, "the departed server left its record behind"
      refute File.socket?(File.join(siding_state_dir, "sock")),
             "the departed server left its socket behind"

      result = siding_invoke("rails", "runner", "print 'ok'")

      assert_equal 0, result.exitstatus, result.stderr
      assert_equal "ok", result.stdout.split.last
    end

    def test_a_server_overdue_for_idle_expiry_waits_for_the_command_it_is_running
      idle = { "SIDING_IDLE_TIMEOUT" => IDLE_TIMEOUT.to_s }
      warm_up(env: idle)

      supervisor_path = File.join(scratch_dir, "supervisor.pid")
      script = "File.write(#{supervisor_path.inspect}, Process.ppid); " \
               "sleep #{IDLE_TIMEOUT * 2}; print 'finished'"
      result = siding_invoke("rails", "runner", script, env: idle)

      assert_equal 0, result.exitstatus, result.stderr
      assert_equal "finished", result.stdout.split.last,
                   "the command did not run to completion under a server that was overdue to leave"

      supervisor = wait_for_pid(supervisor_path)
      refute_nil supervisor, "the command never reported which process was supervising it"
      refute_equal 1, supervisor, "the worker was reparented away from its supervisor"
      assert wait_until(IDLE_TIMEOUT + 15) { !alive?(supervisor) },
             "the server never left, even once it had nothing left to run"
    end

    def teardown
      super
    ensure
      FileUtils.remove_entry(@scratch_dir) if @scratch_dir && File.directory?(@scratch_dir)
    end

    private

    Lingering = Struct.new(:client_pid, :pid, :child_path, keyword_init: true)

    def scratch_dir
      @scratch_dir ||= Dir.mktmpdir("siding-lifecycle")
    end

    def warm_up(env: {})
      result = siding_invoke("rails", "runner", "print 'ok'", env: env)

      assert_equal 0, result.exitstatus, result.stderr
      pid = siding_server_pid
      refute_nil pid, "nothing was warmed up"
      pid
    end

    def start_lingering_command(spawn_child: false)
      pid_path = File.join(scratch_dir, "worker.pid")
      child_path = File.join(scratch_dir, "child.pid")

      script = +"File.write(#{pid_path.inspect}, Process.pid)"
      if spawn_child
        script << "; child = spawn('sleep', '#{LINGER}')"
        script << "; File.write(#{child_path.inspect}, child)"
      end
      script << "; sleep #{LINGER}"

      client = Process.spawn(siding_env, RbConfig.ruby, EXE, "rails", "runner", script,
                             chdir: FIXTURE_APP, out: File::NULL, err: File::NULL)
      track_pid(client)
      pid = wait_for_pid(pid_path)

      refute_nil pid, "the lingering command never reported its worker pid"
      track_pid(pid)
      Lingering.new(client_pid: client, pid: pid, child_path: child_path)
    end

    def wait_for_pid(path, timeout = 60.0)
      wait_until(timeout) { File.file?(path) && !File.read(path).strip.empty? }
      return nil unless File.file?(path)

      pid = File.read(path).strip.to_i
      pid.positive? ? track_pid(pid) : nil
    rescue SystemCallError
      nil
    end

    def wait_until(timeout = 10.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return true if yield
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
    end
  end
end
