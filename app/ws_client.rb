# frozen_string_literal: true

# Minimal stdlib-only ActionCable v1 WebSocket client for the integration
# harness (RFC 6455 text frames, client-side masking, actioncable-v1-json
# subprotocol). Speaks to beam's ActionCable-compatible cable server and
# triggers Rails-side broadcasts over the app's HTTP harness endpoints, so a
# single process observes the whole seam: Rails broadcast -> Solid Cable row
# -> beam poller -> WebSocket delivery.
#
# Usage:
#   ruby ws_client.rb roundtrip  WS_URL APP_BASE MESSAGE
#   ruby ws_client.rb chaoscable WS_URL APP_BASE PRE_MESSAGE POST_MESSAGE
#
# roundtrip:  connect, subscribe (Turbo signed stream), broadcast MESSAGE via
#             the Rails app, expect it delivered. Prints ROUNDTRIP_OK.
# chaoscable: roundtrip PRE_MESSAGE, print READY_FOR_KILL, survive the cable
#             server being killed (detect close, reconnect, resubscribe),
#             assert PRE_MESSAGE is NOT replayed, then roundtrip POST_MESSAGE.
#             Prints CHAOS_CABLE_OK.

require "socket"
require "uri"
require "json"
require "base64"
require "securerandom"
require "net/http"

STDOUT.sync = true

# Ruby 3.4 removed the global TimeoutError alias; use a harness-local error.
class WsTimeout < StandardError; end

class WsClient
  OPCODE_TEXT = 0x1
  OPCODE_CLOSE = 0x8
  OPCODE_PING = 0x9
  OPCODE_PONG = 0xA

  def initialize(url)
    uri = URI(url)
    @host = uri.host
    @port = uri.port || 80
    @path = uri.path.empty? ? "/" : uri.path
    @sock = TCPSocket.new(@host, @port)
    handshake!
  end

  def handshake!
    key = Base64.strict_encode64(SecureRandom.random_bytes(16))
    @sock.write(
      "GET #{@path} HTTP/1.1\r\n" \
      "Host: #{@host}:#{@port}\r\n" \
      "Upgrade: websocket\r\n" \
      "Connection: Upgrade\r\n" \
      "Sec-WebSocket-Key: #{key}\r\n" \
      "Sec-WebSocket-Version: 13\r\n" \
      "Sec-WebSocket-Protocol: actioncable-v1-json\r\n" \
      "Origin: http://#{@host}\r\n\r\n"
    )
    response = +""
    response << @sock.readpartial(1) until response.end_with?("\r\n\r\n")
    raise "websocket handshake refused:\n#{response}" unless response.start_with?("HTTP/1.1 101")
  end

  def send_text(payload)
    send_frame(OPCODE_TEXT, payload)
  end

  def close
    send_frame(OPCODE_CLOSE, "")
  rescue IOError, SystemCallError
    nil
  ensure
    @sock.close rescue nil
  end

  # Yields each parsed JSON message until the block returns truthy or the
  # deadline passes (-> raises) or the peer closes (-> :closed).
  def each_message(timeout:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise WsTimeout, "no matching frame within #{timeout}s" if remaining <= 0

      frame = read_frame(remaining)
      return :closed if frame.nil?

      opcode, payload = frame
      case opcode
      when OPCODE_PING then send_frame(OPCODE_PONG, payload)
      when OPCODE_CLOSE then return :closed
      when OPCODE_TEXT
        data = JSON.parse(payload) rescue next
        result = yield(data)
        return result if result
      end
    end
  end

  private

  def send_frame(opcode, payload)
    payload = payload.b
    mask = SecureRandom.random_bytes(4)
    header = [0x80 | opcode].pack("C")
    len = payload.bytesize
    header <<
      if len < 126 then [0x80 | len].pack("C")
      elsif len < 65_536 then [0x80 | 126, len].pack("Cn")
      else [0x80 | 127, len >> 32, len & 0xFFFFFFFF].pack("CNN")
      end
    masked = payload.bytes.each_with_index.map { |b, i| b ^ mask.getbyte(i % 4) }.pack("C*")
    @sock.write(header + mask + masked)
  end

  # nil on EOF/close; [opcode, payload] otherwise. Handles fragmentation.
  def read_frame(timeout)
    opcode = nil
    buffer = +""
    loop do
      head = read_bytes(2, timeout)
      return nil if head.nil?

      b1, b2 = head.bytes
      fin = (b1 & 0x80) != 0
      op = b1 & 0x0F
      masked = (b2 & 0x80) != 0
      len = b2 & 0x7F
      len = read_bytes(2, timeout).unpack1("n") if len == 126
      if len == 127
        hi, lo = read_bytes(8, timeout).unpack("NN")
        len = (hi << 32) | lo
      end
      mask = masked ? read_bytes(4, timeout) : nil
      payload = len.zero? ? +"" : read_bytes(len, timeout)
      return nil if payload.nil?
      payload = payload.bytes.each_with_index.map { |b, i| b ^ mask.getbyte(i % 4) }.pack("C*") if mask

      opcode = op unless op.zero? # continuation frames keep the first opcode
      buffer << payload
      return [opcode, buffer] if fin
    end
  end

  def read_bytes(n, timeout)
    buffer = +""
    while buffer.bytesize < n
      ready = IO.select([@sock], nil, nil, timeout)
      raise WsTimeout, "read timed out" unless ready
      chunk = @sock.read_nonblock(n - buffer.bytesize, exception: false)
      return nil if chunk.nil? || chunk == :eof
      next if chunk == :wait_readable
      buffer << chunk
    end
    buffer
  rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
    nil
  end
end

module Harness
  module_function

  def http_get(base, path)
    uri = URI("#{base}#{path}")
    response = Net::HTTP.get_response(uri)
    raise "GET #{uri} -> #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)
    response.body
  end

  def signed_stream_name(app_base)
    http_get(app_base, "/integration/signed_stream?name=integration").strip
  end

  def broadcast(app_base, message)
    http_get(app_base, "/integration/broadcast?message=#{message}")
  end

  def identifier(signed)
    JSON.generate({ "channel" => "Turbo::StreamsChannel", "signed_stream_name" => signed })
  end

  # Connect + welcome + confirmed subscription. Returns [client, identifier].
  def connect_and_subscribe(ws_url, signed, timeout: 15)
    client = WsClient.new(ws_url)
    id = identifier(signed)
    result = client.each_message(timeout: timeout) { |m| m["type"] == "welcome" }
    raise "connection closed before welcome" if result == :closed

    client.send_text(JSON.generate({ "command" => "subscribe", "identifier" => id }))
    result = client.each_message(timeout: timeout) do |m|
      raise "subscription rejected: #{m.inspect}" if m["type"] == "reject_subscription"
      m["type"] == "confirm_subscription" && m["identifier"] == id
    end
    raise "connection closed before subscription confirm" if result == :closed

    [client, id]
  end

  def expect_broadcast(client, id, token, timeout: 20)
    result = client.each_message(timeout: timeout) do |m|
      m["identifier"] == id && m["message"].to_s.include?(token)
    end
    raise "connection closed while waiting for broadcast #{token}" if result == :closed
  end

  # Assert NO frame containing token arrives for `seconds` (replay guard).
  def expect_silence(client, token, seconds)
    client.each_message(timeout: seconds) do |m|
      raise "REPLAYED stale broadcast: #{m.inspect}" if m["message"].to_s.include?(token)
      false
    end
    raise "connection closed during replay-silence window"
  rescue WsTimeout
    :quiet # timing out without seeing the token is the success case
  end

  def reconnect(ws_url, signed, budget: 90)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + budget
    attempt = 0
    begin
      attempt += 1
      connect_and_subscribe(ws_url, signed, timeout: 10)
    rescue StandardError => e
      raise "reconnect failed after #{attempt} attempts: #{e}" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 1
      retry
    end
  end
end

mode, ws_url, app_base, *args = ARGV
abort "usage: ws_client.rb roundtrip|chaoscable WS_URL APP_BASE MESSAGE..." unless ws_url && app_base

signed = Harness.signed_stream_name(app_base)

case mode
when "roundtrip"
  message = args.fetch(0)
  client, id = Harness.connect_and_subscribe(ws_url, signed)
  Harness.broadcast(app_base, message)
  Harness.expect_broadcast(client, id, message)
  client.close
  puts "ROUNDTRIP_OK #{message}"
when "chaoscable"
  pre, post = args.fetch(0), args.fetch(1)
  client, id = Harness.connect_and_subscribe(ws_url, signed)
  Harness.broadcast(app_base, pre)
  Harness.expect_broadcast(client, id, pre)
  puts "READY_FOR_KILL"

  # The harness now SIGKILLs the cable server; wait for our connection to die.
  closed = client.each_message(timeout: 90) { |_| false } rescue nil
  raise "cable connection did not close after kill" unless closed == :closed
  puts "CONNECTION_LOST"

  client, id = Harness.reconnect(ws_url, signed)
  puts "RECONNECTED"

  # No replay: the pre-kill broadcast must not be redelivered to the fresh
  # subscription (beam baselines each stream at MAX(id) on subscribe).
  Harness.expect_silence(client, pre, 3)
  Harness.broadcast(app_base, post)
  Harness.expect_broadcast(client, id, post)
  client.close
  puts "CHAOS_CABLE_OK"
else
  abort "unknown mode #{mode.inspect}"
end
