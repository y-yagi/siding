# frozen_string_literal: true

require "test_helper"

module Siding
  class ShortRuntimeDirTest < Minitest::Test
    def test_a_socket_fits_inside_the_runtime_directory_it_hands_out
      dir = ShortRuntimeDir.make
      socket = dir.bytesize + ShortRuntimeDir::TOOL_SUFFIX_BYTES

      assert_operator socket, :<=, ShortRuntimeDir::SOCKET_LIMIT_BYTES,
                      "#{dir} leaves #{socket} bytes for a socket path, over the " \
                      "#{ShortRuntimeDir::SOCKET_LIMIT_BYTES}-byte limit. Every accelerated test " \
                      "would run unaccelerated and read as a broken tool"
    ensure
      FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    end

    def test_it_measures_against_the_limit_the_tool_itself_enforces
      assert_operator ShortRuntimeDir::SOCKET_LIMIT_BYTES, :<=,
                      Platform::UNIX_SOCKET_PATH_LIMIT - 1,
                      "the harness allows a longer socket path than the tool accepts"
    end

    def test_the_directory_is_owner_only
      dir = ShortRuntimeDir.make

      assert_equal 0o700, File.stat(dir).mode & 0o777
    ensure
      FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    end
  end
end
