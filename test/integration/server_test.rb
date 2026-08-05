# frozen_string_literal: true

require "test_helper"
require "net/http"
require "socket"

module Siding
  class ServerTest < Minitest::Test
    include TestSupport
    include FixtureEdits

    def test_rails_server_runs_against_the_warm_application
      port = free_port
      pid = spawn_rails_server(port)

      assert warm_application?, "rails server did not boot against a warm application"

      Process.kill("INT", pid)
      _, status = Process.waitpid2(pid)

      assert status.success?, "rails server did not shut down cleanly on SIGINT (#{status.inspect})"
    end

    def test_a_running_server_does_not_serve_stale_code
      write_smoke_controller("first")
      edit_fixture("config/routes.rb") do |source|
        source.sub("Rails.application.routes.draw do", "Rails.application.routes.draw do\n  root \"smoke#index\"")
      end

      port = free_port
      pid = spawn_rails_server(port)

      assert_equal "first", http_get(port, "/"), "the server did not boot the fixture's initial edit"

      write_smoke_controller("second")

      assert wait_until(10) { http_get(port, "/") == "second" }, <<~MESSAGE
        the running server kept serving the pre-edit response -- Rails' own reloader should have
        picked up the controller change without a restart.
      MESSAGE

      Process.kill("INT", pid)
      Process.waitpid2(pid)
    end

    def test_the_daemon_flag_is_passed_through
      result = siding_invoke("rails", "server", "--help", "-d")

      assert_equal 0, result.exitstatus, result.stderr
      refute warm_application?, "the daemon flag should never touch the warm application"
    end

    private

    def write_smoke_controller(word)
      edit_fixture("app/controllers/smoke_controller.rb") do
        <<~RUBY
          class SmokeController < ApplicationController
            def index
              render plain: "#{word}"
            end
          end
        RUBY
      end
    end

    def spawn_rails_server(port)
      pid = Process.spawn(siding_env, RbConfig.ruby, EXE, "rails", "server", "-p", port.to_s, "-b", "127.0.0.1",
                           chdir: FIXTURE_APP, out: File::NULL, err: File::NULL)
      # Tracked before any assertion that could raise, so a failed readiness check still leaves
      # teardown's assert_no_surviving_processes able to find and reap this child (Invariant 8).
      track_pid(pid)
      assert wait_until(60) { http_up?(port) }, "the accelerated rails server never came up on port #{port}"
      pid
    end

    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    def http_up?(port)
      Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/up")).code == "200"
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError
      false
    end

    def http_get(port, path)
      Net::HTTP.get(URI("http://127.0.0.1:#{port}#{path}"))
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError
      nil
    end

    def wait_until(timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return true if yield
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
    end
  end
end
