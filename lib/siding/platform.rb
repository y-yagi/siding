# frozen_string_literal: true

require "rbconfig"

module Siding
  module Platform
    UNIX_SOCKET_PATH_LIMIT = 104

    module_function

    def host_os = RbConfig::CONFIG["host_os"]
    def linux? = host_os.match?(/linux/i)
    def macos? = host_os.match?(/darwin/i)
    def windows? = host_os.match?(/mswin|mingw|cygwin/i)
    def supported? = linux? || macos?

    def unsupported_reason
      return nil if supported?

      if windows?
        "Windows is not supported: it provides neither fork() with copy-on-write nor " \
          "file-descriptor passing over Unix domain sockets. Commands run unaccelerated."
      else
        "Unrecognized platform #{host_os.inspect}. Only Linux and macOS are supported. " \
          "Commands run unaccelerated."
      end
    end

    def description
      return "Linux" if linux?
      return "macOS" if macos?
      return "Windows" if windows?

      host_os.to_s
    end
  end
end
