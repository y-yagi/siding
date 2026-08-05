# frozen_string_literal: true

require "json"
require "socket"

socket_path, info_path, protocol_version = ARGV
protocol_version = Integer(protocol_version)

File.unlink(socket_path) if File.exist?(socket_path)
server = UNIXServer.new(socket_path)

File.write(info_path, JSON.generate(
                        "pid" => Process.pid,
                        "protocol_version" => protocol_version,
                        "revision_label" => "previous-version",
                        "started_at" => Time.now.to_i
                      ))

# TERM is how `siding stop` ends a server, and a script that ignored it would leave the test
# asserting on a process the tool believes it has already removed.
trap("TERM") do
  File.unlink(socket_path) if File.exist?(socket_path)
  exit 0
end

$stdout.puts "ready"
$stdout.flush

def read_message(io)
  header = io.recv(4)
  return nil if header.nil? || header.empty?

  body = +""
  body << io.recv(header.unpack1("N") - body.bytesize) while body.bytesize < header.unpack1("N")
  JSON.parse(body)
end

def write_message(io, payload)
  body = JSON.generate(payload)
  io.write([body.bytesize].pack("N") + body)
  io.flush
end

loop do
  connection = server.accept
  begin
    read_message(connection)
    write_message(connection, "type" => "VersionMismatch", "protocol_version" => protocol_version)
  rescue StandardError
    nil
  ensure
    connection.close unless connection.closed?
  end
end
