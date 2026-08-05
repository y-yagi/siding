# frozen_string_literal: true

require "test_helper"

class ProtocolTest < Minitest::Test
  def setup
    @client, @server = UNIXSocket.pair
  end

  def teardown
    [@client, @server].each { |io| io.close unless io.closed? }
    super
  end

  def test_a_message_round_trips
    Siding::Protocol.write_message(@client, Siding::Protocol::RUN, argv: %w[test foo], cwd: "/tmp")

    message = Siding::Protocol.read_message(@server)

    assert_equal Siding::Protocol::RUN, message.type
    assert_equal %w[test foo], message["argv"]
    assert_equal "/tmp", message["cwd"]
  end

  def test_symbol_and_string_payload_keys_are_the_same_message
    Siding::Protocol.write_message(@client, Siding::Protocol::SIGNAL, signal: "INT")
    from_symbol = Siding::Protocol.read_message(@server)

    Siding::Protocol.write_message(@client, Siding::Protocol::SIGNAL, "signal" => "INT")
    from_string = Siding::Protocol.read_message(@server)

    assert_equal from_symbol.payload, from_string.payload
  end

  def test_messages_stay_in_order_and_do_not_bleed_into_each_other
    Siding::Protocol.write_message(@client, Siding::Protocol::STARTED, pid: 1)
    Siding::Protocol.write_message(@client, Siding::Protocol::FINISHED, exit_code: 0)

    assert_equal Siding::Protocol::STARTED, Siding::Protocol.read_message(@server).type
    assert_equal Siding::Protocol::FINISHED, Siding::Protocol.read_message(@server).type
  end

  def test_a_clean_close_between_messages_reads_as_end_of_stream
    @client.close

    assert_nil Siding::Protocol.read_message(@server)
  end

  def test_a_truncated_body_is_not_read_as_a_complete_message
    body = JSON.generate({ "type" => Siding::Protocol::RUN, "argv" => %w[test] })
    @client.write([body.bytesize].pack(Siding::Protocol::LENGTH_FORMAT) + body[0, 3])
    @client.close

    assert_raises(Siding::Protocol::TruncatedMessage) { Siding::Protocol.read_message(@server) }
  end

  def test_a_truncated_length_prefix_is_not_read_as_a_complete_message
    @client.write("\x00\x00")
    @client.close

    assert_raises(Siding::Protocol::TruncatedMessage) { Siding::Protocol.read_message(@server) }
  end

  def test_an_announced_length_over_the_limit_is_refused_without_allocating_it
    @client.write([Siding::Protocol::MAX_MESSAGE_BYTES + 1].pack(Siding::Protocol::LENGTH_FORMAT))
    @client.flush

    assert_raises(Siding::Protocol::MessageTooLarge) { Siding::Protocol.read_message(@server) }
  end

  def test_an_oversized_message_is_refused_by_the_writer_too
    oversized = "x" * (Siding::Protocol::MAX_MESSAGE_BYTES + 1)

    assert_raises(Siding::Protocol::MessageTooLarge) do
      Siding::Protocol.write_message(@client, Siding::Protocol::RUN, argv: [oversized])
    end
  end

  def test_a_malformed_body_is_a_protocol_error_not_a_crash
    body = "{not json"
    @client.write([body.bytesize].pack(Siding::Protocol::LENGTH_FORMAT) + body)
    @client.flush

    assert_raises(Siding::Protocol::ProtocolError) { Siding::Protocol.read_message(@server) }
  end

  def test_a_body_without_a_type_is_a_protocol_error
    body = JSON.generate({ "argv" => [] })
    @client.write([body.bytesize].pack(Siding::Protocol::LENGTH_FORMAT) + body)
    @client.flush

    assert_raises(Siding::Protocol::ProtocolError) { Siding::Protocol.read_message(@server) }
  end

  def test_descriptors_round_trip_in_the_agreed_order
    reader, writer = IO.pipe
    _, second_writer = IO.pipe

    Siding::Protocol.send_streams(@client, stdin: reader, stdout: writer, stderr: second_writer)
    streams = Siding::Protocol.receive_streams(@server)

    assert_equal %i[stdin stdout stderr], streams.keys

    streams[:stdout].write("through the passed descriptor")
    streams[:stdout].flush
    assert_equal "through the passed descriptor", reader.readpartial(64)
  ensure
    [reader, writer, second_writer, *streams&.values].each { |io| io&.close unless io&.closed? }
  end

  def test_a_peer_that_dies_before_passing_descriptors_is_reported_as_truncation
    @client.close

    assert_raises(Siding::Protocol::TruncatedMessage) { Siding::Protocol.receive_streams(@server) }
  end

  def test_matching_versions_shake_hands
    server = Thread.new { Siding::Protocol.server_handshake(@server) }

    assert_equal Siding::Protocol::VERSION, Siding::Protocol.client_handshake(@client)
    assert server.value
  end

  def test_a_version_mismatch_is_refused_rather_than_negotiated
    server = Thread.new do
      Siding::Protocol.read_message(@server)
      Siding::Protocol.write_message(
        @server, Siding::Protocol::VERSION_MISMATCH, protocol_version: Siding::Protocol::VERSION + 1
      )
    end

    error = assert_raises(Siding::Protocol::VersionMismatch) do
      Siding::Protocol.client_handshake(@client)
    end
    server.join

    assert_equal Siding::Protocol::VERSION + 1, error.server_version
    assert_equal Siding::Protocol::VERSION, error.client_version
  end

  def test_the_server_tells_a_mismatched_client_its_own_version_and_declines
    Siding::Protocol.write_message(@client, Siding::Protocol::HELLO,
                                   protocol_version: Siding::Protocol::VERSION + 99)

    refute Siding::Protocol.server_handshake(@server)

    reply = Siding::Protocol.read_message(@client)
    assert_equal Siding::Protocol::VERSION_MISMATCH, reply.type
    assert_equal Siding::Protocol::VERSION, reply["protocol_version"]
  end

  def test_the_client_raises_when_the_server_dies_during_the_handshake
    server = Thread.new do
      Siding::Protocol.read_message(@server)
      @server.close
    end

    assert_raises(Siding::Protocol::TruncatedMessage) { Siding::Protocol.client_handshake(@client) }
    server.join
  end

  def test_the_server_rejects_a_first_message_that_is_not_hello
    Siding::Protocol.write_message(@client, Siding::Protocol::RUN, argv: [])

    assert_raises(Siding::Protocol::ProtocolError) { Siding::Protocol.server_handshake(@server) }
  end

  def test_the_client_rejects_an_unexpected_reply_to_hello
    server = Thread.new do
      Siding::Protocol.read_message(@server)
      Siding::Protocol.write_message(@server, Siding::Protocol::BOOTING, reason: "cold")
    end

    assert_raises(Siding::Protocol::ProtocolError) { Siding::Protocol.client_handshake(@client) }
    server.join
  end
end
