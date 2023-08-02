require 'test_helper'

class TestCccTCPI < Pitchfork::Test
  def test_ccc_tcpi
    start_pid = $$
    host = '127.0.0.1'
    port = unused_port

    rd, wr = Pitchfork::Info.keep_ios(IO.pipe)
    sleep_pipe = Pitchfork::Info.keep_ios(IO.pipe)
    ready_read, ready_write = Pitchfork::Info.keep_ios(IO.pipe)

    pid = fork do
      ready_read.close
      sleep_pipe[1].close
      reqs = 0
      rd.close
      worker_pid = nil
      app = lambda do |env|
        worker_pid ||= begin
          at_exit { wr.write(reqs.to_s) if worker_pid == $$ }
          $$
        end
        reqs += 1

        # will wake up when writer closes
        sleep_pipe[0].read if env['PATH_INFO'] == '/sleep'

        [ 200, [ %w(content-length 0),  %w(content-type text/plain) ], [] ]
      end
      opts = {
        listeners: [ "#{host}:#{port}" ],
        worker_processes: 1,
        check_client_connection: true,
      }
      uni = Pitchfork::HttpServer.new(app, opts)
      uni.start
      ready_write.write("ready\n")
      ready_write.close
      uni.join
    end
    wr.close
    ready_write.close

    ready_read.wait(2)

    # make sure the server is running, at least
    client = tcp_socket(host, port)
    client.write("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
    assert client.wait(10), 'never got response from server'
    res = client.read
    assert_match %r{\AHTTP/1\.1 200}, res, 'got part of first response'
    assert_match %r{\r\n\r\n\z}, res, 'got end of response, server is ready'
    client.close

    # start a slow request...
    sleeper = tcp_socket(host, port)
    sleeper.write("GET /sleep HTTP/1.1\r\nHost: example.com\r\n\r\n")

    # and a bunch of aborted ones
    nr = 100
    nr.times do |i|
      client = tcp_socket(host, port)
      client.write("GET /collections/#{rand(10000)} HTTP/1.1\r\n" \
                   "Host: example.com\r\n\r\n")
      client.close
    end
    sleep_pipe[1].close # wake up the reader in the worker
    res = sleeper.read
    assert_match %r{\AHTTP/1\.1 200}, res, 'got part of first sleeper response'
    assert_match %r{\r\n\r\n\z}, res, 'got end of sleeper response'
    sleeper.close
    kpid = pid
    pid = nil
    Process.kill(:QUIT, kpid)
    _, status = Process.waitpid2(kpid)
    assert_predicate status, :success?
    reqs = rd.read.to_i
    warn "server got #{reqs} requests with #{nr} CCC aborted\n" if $DEBUG
    assert_operator reqs, :<, nr
    assert_operator reqs, :>=, 2, 'first 2 requests got through, at least'
  ensure
    return if start_pid != $$
    if pid
      Process.kill(:QUIT, pid)
      _, status = Process.waitpid2(pid)
      unless $!
        assert_predicate status, :success?
      end
    end
    rd.close if rd
  end
end
