# frozen_string_literal: true

require "json"
require "socket"

require_relative "error"

module Siding
  module Protocol
    VERSION = 1

    LENGTH_BYTES = 4
    LENGTH_FORMAT = "N"

    MAX_MESSAGE_BYTES = 1024 * 1024

    # Client -> server.
    HELLO = "Hello"
    RUN = "Run"
    SIGNAL = "Signal"
    STATUS = "Status"
    STOP = "Stop"

    # Server -> client.
    WELCOME = "Welcome"
    VERSION_MISMATCH = "VersionMismatch"
    BOOTING = "Booting"
    BOOT_FAILED = "BootFailed"
    STARTED = "Started"
    FINISHED = "Finished"
    STATUS_REPORT = "StatusReport"

    class ProtocolError < Error; end
    class TruncatedMessage < ProtocolError; end
    class MessageTooLarge < ProtocolError; end

    class VersionMismatch < ProtocolError
      attr_reader :server_version, :client_version

      def initialize(server_version:, client_version: VERSION)
        @server_version = server_version
        @client_version = client_version
        super("server speaks protocol version #{server_version}, this client speaks #{client_version}")
      end
    end

    Message = Struct.new(:type, :payload, keyword_init: true) do
      def [](key) = payload[key]
    end

    module_function

    def write_message(io, type, payload = {})
      body = JSON.generate({ "type" => type }.merge(stringify(payload)))
      raise MessageTooLarge, "message of #{body.bytesize} bytes exceeds #{MAX_MESSAGE_BYTES}" if
        body.bytesize > MAX_MESSAGE_BYTES

      # Length and body in a single write. Two writes would give a reader a window in which a
      # crash leaves a valid-looking prefix with nothing behind it -- exactly the state the
      # framing is here to make unrepresentable.
      io.write([body.bytesize].pack(LENGTH_FORMAT) + body)
      io.flush if io.respond_to?(:flush)
      body.bytesize
    end

    def read_message(io)
      header = read_exactly(io, LENGTH_BYTES, allow_eof: true)
      return nil if header.nil?

      length = header.unpack1(LENGTH_FORMAT)
      raise MessageTooLarge, "peer announced #{length} bytes, over the #{MAX_MESSAGE_BYTES} limit" if
        length > MAX_MESSAGE_BYTES

      body = read_exactly(io, length)
      parsed = begin
        JSON.parse(body)
      rescue JSON::ParserError => e
        raise ProtocolError, "malformed message body: #{e.message}"
      end

      raise ProtocolError, "message has no type" unless parsed.is_a?(Hash) && parsed["type"]

      Message.new(type: parsed.delete("type"), payload: parsed)
    end

    def read_exactly(io, count, allow_eof: false)
      return +"" if count.zero?

      buffer = +""
      while buffer.bytesize < count
        chunk = read_some(io, count - buffer.bytesize)
        if chunk.nil? || chunk.empty?
          return nil if buffer.empty? && allow_eof

          raise TruncatedMessage, "peer sent #{buffer.bytesize} of #{count} bytes before closing"
        end
        buffer << chunk
      end
      buffer
    end

    def read_some(io, count)
      io.respond_to?(:recv) ? io.recv(count) : io.read(count)
    end

    def stringify(payload)
      payload.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end

    STREAM_ORDER = %i[stdin stdout stderr].freeze

    def send_streams(io, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      [stdin, stdout, stderr].each { |stream| io.send_io(stream) }
      STREAM_ORDER
    end

    def receive_streams(io)
      STREAM_ORDER.each_with_object({}) { |name, streams| streams[name] = io.recv_io }
    rescue EOFError, SocketError, SystemCallError => e
      # A peer that dies mid-pass surfaces as `SocketError` ("file descriptor was not passed")
      # rather than as EOF, because the control message arrives empty rather than not at all.
      # Both mean the same thing here: the descriptors we were promised are not coming.
      raise TruncatedMessage, "peer closed while passing descriptors: #{e.message}"
    end

    def client_handshake(io)
      write_message(io, HELLO, protocol_version: VERSION)
      reply = read_message(io)
      raise TruncatedMessage, "server closed during handshake" if reply.nil?

      case reply.type
      when WELCOME
        reply["protocol_version"]
      when VERSION_MISMATCH
        raise VersionMismatch.new(server_version: reply["protocol_version"])
      else
        raise ProtocolError, "unexpected #{reply.type.inspect} in response to #{HELLO}"
      end
    end

    def server_handshake(io)
      hello = read_message(io)
      raise TruncatedMessage, "client closed during handshake" if hello.nil?
      raise ProtocolError, "expected #{HELLO}, got #{hello.type.inspect}" unless hello.type == HELLO

      if hello["protocol_version"] == VERSION
        write_message(io, WELCOME, protocol_version: VERSION)
        true
      else
        write_message(io, VERSION_MISMATCH, protocol_version: VERSION)
        false
      end
    end
  end
end
