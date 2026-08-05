# frozen_string_literal: true

require "tmpdir"

module Siding
  module ShortRuntimeDir
    TOOL_SUFFIX_BYTES = "/siding/000000000000/sock".bytesize
    SOCKET_LIMIT_BYTES = 103

    module_function

    def base
      @base ||= File.directory?("/tmp") && File.writable?("/tmp") ? "/tmp" : Dir.tmpdir
    end

    def make = Dir.mktmpdir("siding", base)
  end
end
