# -*- encoding: binary -*-
require 'pitchfork/pitchfork_http'
require 'pitchfork/flock'
require 'pitchfork/soft_timeout'
require 'pitchfork/shared_memory'
require 'pitchfork/info'

module Pitchfork
  # This is the process manager of Pitchfork. This manages worker
  # processes which in turn handle the I/O and application process.
  # Listener sockets are started in the master process and shared with
  # forked worker children.
  class HttpServer
    class TimeoutHandler
      class Info
        attr_reader :thread, :rack_env

        def initialize(thread, rack_env)
          @thread = thread
          @rack_env = rack_env
        end

        def copy_thread_variables!
          current_thread = Thread.current
          @thread.keys.each do |key|
            current_thread[key] = @thread[key]
          end
          @thread.thread_variables.each do |variable|
            current_thread.thread_variable_set(variable, @thread.thread_variable_get(variable))
          end
        end
      end

      attr_writer :rack_env, :timeout_request # :nodoc:

      def initialize(server, worker, callback) # :nodoc:
        @server = server
        @worker = worker
        @callback = callback
        @rack_env = nil
        @timeout_request = nil
      end

      def inspect
        "#<Pitchfork::HttpServer::TimeoutHandler##{object_id}>"
      end

      def call(original_thread) # :nodoc:
        begin
          @server.logger.error("worker=#{@worker.nr} pid=#{@worker.pid} timed out, exiting")
          if @callback
            @callback.call(@server, @worker, Info.new(original_thread, @rack_env))
          end
        rescue => error
          Pitchfork.log_error(@server.logger, "after_worker_timeout error", error)
        end
        @server.worker_exit(@worker)
      end

      def finished # :nodoc:
        @timeout_request.finished
      end

      def deadline
        @timeout_request.deadline
      end

      def extend_deadline(extra_time)
        extra_time = Integer(extra_time)
        @worker.deadline += extra_time
        @timeout_request.extend_deadline(extra_time)
        self
      end
    end

    # :stopdoc:
    attr_accessor :app, :timeout, :soft_timeout, :cleanup_timeout, :worker_processes,
                  :after_worker_fork, :after_mold_fork,
                  :listener_opts, :children,
                  :orig_app, :config, :ready_pipe,
                  :default_middleware, :early_hints
    attr_writer   :after_worker_exit, :before_worker_exit, :after_worker_ready, :after_request_complete,
                  :refork_condition, :after_worker_timeout, :after_worker_hard_timeout

    attr_reader :logger
    include Pitchfork::SocketHelper
    include Pitchfork::HttpResponse

    # all bound listener sockets
    # note: this is public used by raindrops, but not recommended for use
    # in new projects
    LISTENERS = []

    NOOP = '.'

    # :startdoc:
    # This Hash is considered a stable interface and changing its contents
    # will allow you to switch between different installations of Pitchfork
    # or even different installations of the same applications without
    # downtime.  Keys of this constant Hash are described as follows:
    #
    # * 0 - the path to the pitchfork executable
    # * :argv - a deep copy of the ARGV array the executable originally saw
    # * :cwd - the working directory of the application, this is where
    # you originally started Pitchfork.
    # TODO: Can we get rid of this?
    START_CTX = {
      :argv => ARGV.map(&:dup),
      0 => $0.dup,
    }
    # We favor ENV['PWD'] since it is (usually) symlink aware for Capistrano
    # and like systems
    START_CTX[:cwd] = begin
      a = File.stat(pwd = ENV['PWD'])
      b = File.stat(Dir.pwd)
      a.ino == b.ino && a.dev == b.dev ? pwd : Dir.pwd
    rescue
      Dir.pwd
    end
    # :stopdoc:

    # Creates a working server on host:port (strange things happen if
    # port isn't a Number).  Use HttpServer::run to start the server and
    # HttpServer.run.join to join the thread that's processing
    # incoming requests on the socket.
    def initialize(app, options = {})
      @exit_status = 0
      @app = app
      @respawn = false
      @last_check = Pitchfork.time_now
      @promotion_lock = Flock.new("pitchfork-promotion")

      options = options.dup
      @ready_pipe = options.delete(:ready_pipe)
      @init_listeners = options[:listeners].dup || []
      options[:use_defaults] = true
      self.config = Pitchfork::Configurator.new(options)
      self.listener_opts = {}

      # We use @control_socket differently in the master and worker processes:
      #
      # * The master process never closes or reinitializes this once
      # initialized.  Signal handlers in the master process will write to
      # it to wake up the master from IO.select in exactly the same manner
      # djb describes in https://cr.yp.to/docs/selfpipe.html
      #
      # * The workers immediately close the pipe they inherit.  See the
      # Pitchfork::Worker class for the pipe workers use.
      @control_socket = []
      @children = Children.new
      @sig_queue = [] # signal queue used for self-piping
      @pid = nil

      # we try inheriting listeners first, so we bind them later.
      # we don't write the pid file until we've bound listeners in case
      # pitchfork was started twice by mistake.  Even though our #pid= method
      # checks for stale/existing pid files, race conditions are still
      # possible (and difficult/non-portable to avoid) and can be likely
      # to clobber the pid if the second start was in quick succession
      # after the first, so we rely on the listener binding to fail in
      # that case.  Some tests (in and outside of this source tree) and
      # monitoring tools may also rely on pid files existing before we
      # attempt to connect to the listener(s)
      config.commit!(self, :skip => [:listeners, :pid])
      @orig_app = app
      # list of signals we care about and trap in master.
      @queue_sigs = [
        :QUIT, :INT, :TERM, :USR2, :TTIN, :TTOU ]

      Info.workers_count = worker_processes
      SharedMemory.preallocate_drops(worker_processes)
    end

    # Runs the thing.  Returns self so you can run join on it
    def start(sync = true)
      Pitchfork.enable_child_subreaper # noop if not supported

      # This socketpair is used to wake us up from select(2) in #join when signals
      # are trapped.  See trap_deferred.
      # It's also used by newly spawned children to send their soft_signal pipe
      # to the master when they are spawned.
      @control_socket.replace(Pitchfork.socketpair)
      @master_pid = $$

      # setup signal handlers before writing pid file in case people get
      # trigger happy and send signals as soon as the pid file exists.
      # Note that signals don't actually get handled until the #join method
      @queue_sigs.each { |sig| trap(sig) { @sig_queue << sig; awaken_master } }
      trap(:CHLD) { awaken_master }

      if REFORKING_AVAILABLE
        spawn_initial_mold
        wait_for_pending_workers
        unless @children.mold
          raise BootFailure, "The initial mold failed to boot"
        end
      else
        build_app!
        bind_listeners!
        after_mold_fork.call(self, Worker.new(nil, pid: $$).promoted!)
      end

      if sync
        spawn_missing_workers
        # We could just return here as we'd register them later in #join.
        # However a good part of the test suite assumes #start only return
        # once all initial workers are spawned.
        wait_for_pending_workers
      end

      self
    end

    # replaces current listener set with +listeners+.  This will
    # close the socket if it will not exist in the new listener set
    def listeners=(listeners)
      cur_names, dead_names = [], []
      listener_names.each do |name|
        if name.start_with?('/')
          # mark unlinked sockets as dead so we can rebind them
          (File.socket?(name) ? cur_names : dead_names) << name
        else
          cur_names << name
        end
      end
      set_names = listener_names(listeners)
      dead_names.concat(cur_names - set_names).uniq!

      LISTENERS.delete_if do |io|
        if dead_names.include?(sock_name(io))
          (io.close rescue nil).nil? # true
        else
          set_server_sockopt(io, listener_opts[sock_name(io)])
          false
        end
      end

      (set_names - cur_names).each { |addr| listen(addr) }
    end

    def logger=(obj)
      Pitchfork::HttpParser::DEFAULTS["rack.logger"] = @logger = obj
    end

    # add a given address to the +listeners+ set, idempotently
    # Allows workers to add a private, per-process listener via the
    # after_worker_fork hook.  Very useful for debugging and testing.
    # +:tries+ may be specified as an option for the number of times
    # to retry, and +:delay+ may be specified as the time in seconds
    # to delay between retries.
    # A negative value for +:tries+ indicates the listen will be
    # retried indefinitely, this is useful when workers belonging to
    # different masters are spawned during a transparent upgrade.
    def listen(address, opt = {}.merge(listener_opts[address] || {}))
      address = config.expand_addr(address)
      return if String === address && listener_names.include?(address)

      delay = opt[:delay] || 0.5
      tries = opt[:tries] || 5
      begin
        io = bind_listen(address, opt)
        unless TCPServer === io || UNIXServer === io
          io.autoclose = false
          io = server_cast(io)
        end
        logger.info "listening on addr=#{sock_name(io)} fd=#{io.fileno}"
        LISTENERS << io
        io
      rescue Errno::EADDRINUSE => err
        logger.error "adding listener failed addr=#{address} (in use)"
        raise err if tries == 0
        tries -= 1
        logger.error "retrying in #{delay} seconds " \
                     "(#{tries < 0 ? 'infinite' : tries} tries left)"
        sleep(delay)
        retry
      rescue => err
        logger.fatal "error adding listener addr=#{address}"
        raise err
      end
    end

    # monitors children and receives signals forever
    # (or until a termination signal is sent).  This handles signals
    # one-at-a-time time and we'll happily drop signals in case somebody
    # is signalling us too often.
    def join
      @respawn = true

      proc_name 'master'
      logger.info "master process ready" # test_exec.rb relies on this message
      if @ready_pipe
        begin
          @ready_pipe.syswrite($$.to_s)
        rescue => e
          logger.warn("grandparent died too soon?: #{e.message} (#{e.class})")
        end
        @ready_pipe = @ready_pipe.close rescue nil
      end
      while true
        begin
          if monitor_loop == StopIteration
            break
          end
        rescue => e
          Pitchfork.log_error(@logger, "master loop error", e)
        end
      end
      stop # gracefully shutdown all workers on our way out
      logger.info "master complete"
      @exit_status
    end

    def monitor_loop(sleep = true)
      reap_all_workers

      if REFORKING_AVAILABLE && @respawn && @children.molds.empty?
        logger.info("No mold alive, shutting down")
        @exit_status = 1
        @sig_queue << :TERM
        @respawn = false
      end

      case message = @sig_queue.shift
      when nil
        # avoid murdering workers after our master process (or the
        # machine) comes out of suspend/hibernation
        if (@last_check + @timeout) >= (@last_check = Pitchfork.time_now)
          sleep_time = murder_lazy_workers
        else
          sleep_time = @timeout/2.0 + 1
          @logger.debug("waiting #{sleep_time}s after suspend/hibernation")
        end
        if @respawn
          maintain_worker_count
          restart_outdated_workers if REFORKING_AVAILABLE
        end

        master_sleep(sleep_time) if sleep
      when :QUIT, :TERM # graceful shutdown
        SharedMemory.shutting_down!
        logger.info "#{message} received, starting graceful shutdown"
        return StopIteration
      when :INT # immediate shutdown
        SharedMemory.shutting_down!
        logger.info "#{message} received, starting immediate shutdown"
        stop(false)
        return StopIteration
      when :USR2 # trigger a promotion
        trigger_refork
      when :TTIN
        @respawn = true
        self.worker_processes += 1
      when :TTOU
        self.worker_processes -= 1 if self.worker_processes > 0
      when Message::WorkerSpawned
        worker = @children.update(message)
        # TODO: should we send a message to the worker to acknowledge?
        logger.info "worker=#{worker.nr} pid=#{worker.pid} registered"
      when Message::MoldSpawned
        new_mold = @children.update(message)
        logger.info("mold pid=#{new_mold.pid} gen=#{new_mold.generation} spawned")
      when Message::MoldReady
        old_molds = @children.molds
        new_mold = @children.update(message)
        logger.info("mold pid=#{new_mold.pid} gen=#{new_mold.generation} ready")
        old_molds.each do |old_mold|
          logger.info("Terminating old mold pid=#{old_mold.pid} gen=#{old_mold.generation}")
          old_mold.soft_kill(:TERM)
        end
      else
        logger.error("Unexpected message in sig_queue #{message.inspect}")
        logger.error(@sig_queue.inspect)
      end
    end

    # Terminates all workers, but does not exit master process
    def stop(graceful = true)
      @respawn = false
      SharedMemory.shutting_down!
      wait_for_pending_workers
      self.listeners = []
      limit = Pitchfork.time_now + timeout
      until @children.workers.empty? || Pitchfork.time_now > limit
        if graceful
          soft_kill_each_child(:TERM)
        else
          kill_each_child(:INT)
        end
        if monitor_loop(false) == StopIteration
          return StopIteration
        end
      end
      kill_each_child(:KILL)
      @promotion_lock.unlink
    end

    def worker_exit(worker)
      if @before_worker_exit
        begin
          @before_worker_exit.call(self, worker)
        rescue => error
          Pitchfork.log_error(logger, "before_worker_exit error", error)
        end
      end
      Process.exit
    end

    def rewindable_input
      Pitchfork::HttpParser.input_class.method_defined?(:rewind)
    end

    def rewindable_input=(bool)
      Pitchfork::HttpParser.input_class = bool ?
                                  Pitchfork::TeeInput : Pitchfork::StreamInput
    end

    def client_body_buffer_size
      Pitchfork::TeeInput.client_body_buffer_size
    end

    def client_body_buffer_size=(bytes)
      Pitchfork::TeeInput.client_body_buffer_size = bytes
    end

    def check_client_connection
      Pitchfork::HttpParser.check_client_connection
    end

    def check_client_connection=(bool)
      Pitchfork::HttpParser.check_client_connection = bool
    end

    private

    # wait for a signal handler to wake us up and then consume the pipe
    def master_sleep(sec)
      @control_socket[0].wait(sec) or return
      case message = @control_socket[0].recvmsg_nonblock(exception: false)
      when :wait_readable, NOOP
        nil
      else
        @sig_queue << message
      end
    end

    def awaken_master
      return if $$ != @master_pid
      @control_socket[1].sendmsg_nonblock(NOOP, exception: false) # wakeup master process from select
    end

    # reaps all unreaped workers
    def reap_all_workers
      loop do
        wpid, status = Process.waitpid2(-1, Process::WNOHANG)
        wpid or return
        worker = @children.reap(wpid) and worker.close rescue nil
        if worker
          @after_worker_exit.call(self, worker, status)
        else
          logger.info("reaped unknown subprocess #{status.inspect}")
        end
      rescue Errno::ECHILD
        break
      end
    end

    def listener_sockets
      listener_fds = {}
      LISTENERS.each do |sock|
        sock.close_on_exec = false
        listener_fds[sock.fileno] = sock
      end
      listener_fds
    end

    # forcibly terminate all workers that haven't checked in in timeout seconds.  The timeout is implemented using an unlinked File
    def murder_lazy_workers
      now = Pitchfork.time_now(true)
      next_sleep = @timeout - 1

      @children.workers.each do |worker|
        deadline = worker.deadline
        if 0 == deadline # worker is idle
          next
        elsif deadline > now # worker still has time
          time_left = deadline - now
          if time_left < next_sleep
            next_sleep = time_left
          end
          next
        else # worker is out of time
          next_sleep = 0
          if worker.mold?
            logger.error "mold pid=#{worker.pid} timed out, killing"
          else
            logger.error "worker=#{worker.nr} pid=#{worker.pid} timed out, killing"
          end

          if @after_worker_hard_timeout
            begin
              @after_worker_hard_timeout.call(self, worker)
            rescue => error
              Pitchfork.log_error(@logger, "after_worker_hard_timeout callback", error)
            end
          end

          kill_worker(:KILL, worker.pid) # take no prisoners for hard timeout violations
        end
      end

      next_sleep <= 0 ? 1 : next_sleep
    end

    def trigger_refork
      unless REFORKING_AVAILABLE
        logger.error("This system doesn't support PR_SET_CHILD_SUBREAPER, can't promote a worker")
      end

      unless @children.pending_promotion?
        if new_mold = @children.fresh_workers.first
          @children.promote(new_mold)
        else
          logger.error("No children at all???")
        end
      else
      end
    end

    def after_fork_internal
      @promotion_lock.at_fork
      @control_socket[0].close_write # this is master-only, now
      @ready_pipe.close if @ready_pipe
      Pitchfork::Configurator::RACKUP.clear
      @ready_pipe = @init_listeners = nil

      # The OpenSSL PRNG is seeded with only the pid, and apps with frequently
      # dying workers can recycle pids
      OpenSSL::Random.seed(rand.to_s) if defined?(OpenSSL::Random)
    end

    def spawn_worker(worker, detach:)
      logger.info("worker=#{worker.nr} gen=#{worker.generation} spawning...")

      Pitchfork.fork_sibling do
        worker.pid = Process.pid

        after_fork_internal
        worker_loop(worker)
        worker_exit(worker)
      end

      worker
    end

    def spawn_initial_mold
      mold = Worker.new(nil)
      mold.create_socketpair!
      mold.pid = Pitchfork.clean_fork do
        mold.pid = Process.pid
        @promotion_lock.try_lock
        mold.after_fork_in_child
        build_app!
        bind_listeners!
        mold_loop(mold)
      end
      @promotion_lock.at_fork
      @children.register_mold(mold)
    end

    def spawn_missing_workers
      worker_nr = -1
      until (worker_nr += 1) == @worker_processes
        if @children.nr_alive?(worker_nr)
          next
        end
        worker = Pitchfork::Worker.new(worker_nr)

        if REFORKING_AVAILABLE
          unless @children.mold&.spawn_worker(worker)
            @logger.error("Failed to send a spawn_worker command")
          end
        else
          spawn_worker(worker, detach: false)
        end
        # We could directly register workers when we spawn from the
        # master, like pitchfork does. However it is preferable to
        # always go through the asynchronous registering process for
        # consistency.
        @children.register(worker)
      end
    rescue => e
      @logger.error(e) rescue nil
      exit!
    end

    def wait_for_pending_workers
      while @children.pending_workers?
        master_sleep(0.5)
        if monitor_loop(false) == StopIteration
          return StopIteration
        end
      end
    end

    def maintain_worker_count
      (off = @children.workers_count - worker_processes) == 0 and return
      off < 0 and return spawn_missing_workers
      @children.each_worker { |w| w.nr >= worker_processes and w.soft_kill(:TERM) }
    end

    def restart_outdated_workers
      # If we're already in the middle of forking a new generation, we just continue
      return unless @children.mold

      # We don't shutdown any outdated worker if any worker is already being
      # spawned or a worker is exiting. Only 10% of workers can be reforked at
      # once to minimize the impact on capacity.
      max_pending_workers = (worker_processes * 0.1).ceil
      workers_to_restart = max_pending_workers - @children.restarting_workers_count

      if workers_to_restart > 0
        outdated_workers = @children.workers.select { |w| !w.exiting? && w.generation < @children.mold.generation }
        outdated_workers.each do |worker|
          logger.info("worker=#{worker.nr} pid=#{worker.pid} gen=#{worker.generation} restarting")
          worker.soft_kill(:TERM)
        end
      end
    end

    # if we get any error, try to write something back to the client
    # assuming we haven't closed the socket, but don't get hung up
    # if the socket is already closed or broken.  We'll always ensure
    # the socket is closed at the end of this function
    def handle_error(client, e)
      code = case e
      when EOFError,Errno::ECONNRESET,Errno::EPIPE,Errno::ENOTCONN
        # client disconnected on us and there's nothing we can do
      when Pitchfork::RequestURITooLongError
        414
      when Pitchfork::RequestEntityTooLargeError
        413
      when Pitchfork::HttpParserError # try to tell the client they're bad
        400
      else
        Pitchfork.log_error(@logger, "app error", e)
        500
      end
      if code
        client.write_nonblock(err_response(code, @request.response_start_sent), exception: false)
      end
      client.close
    rescue
    end

    def e103_response_write(client, headers)
      rss = @request.response_start_sent
      buf = rss ? "103 Early Hints\r\n" : "HTTP/1.1 103 Early Hints\r\n"
      headers.each { |key, value| append_header(buf, key, value) }
      buf << (rss ? "\r\nHTTP/1.1 ".freeze : "\r\n".freeze)
      client.write(buf)
    end

    def e100_response_write(client, env)
      # We use String#freeze to avoid allocations under Ruby 2.1+
      # Not many users hit this code path, so it's better to reduce the
      # constant table sizes even for Ruby 2.0 users who'll hit extra
      # allocations here.
      client.write(@request.response_start_sent ?
                   "100 Continue\r\n\r\nHTTP/1.1 ".freeze :
                   "HTTP/1.1 100 Continue\r\n\r\n".freeze)
      env.delete('HTTP_EXPECT'.freeze)
    end

    # once a client is accepted, it is processed in its entirety here
    # in 3 easy steps: read request, call app, write app response
    def process_client(client, timeout_handler)
      env = nil
      @request = Pitchfork::HttpParser.new
      env = @request.read(client)
      timeout_handler.rack_env = env
      env["pitchfork.timeout"] = timeout_handler

      if early_hints
        env["rack.early_hints"] = lambda do |headers|
          e103_response_write(client, headers)
        end
      end

      env["rack.after_reply"] = []

      status, headers, body = @app.call(env)

      begin
        return if @request.hijacked?

        if 100 == status.to_i
          e100_response_write(client, env)
          status, headers, body = @app.call(env)
          return if @request.hijacked?
        end
        @request.headers? or headers = nil
        http_response_write(client, status, headers, body, @request)
      ensure
        body.respond_to?(:close) and body.close
      end

      unless client.closed? # rack.hijack may've close this for us
        begin
          client.shutdown # in case of fork() in Rack app
        rescue Errno::ENOTCONN
        end
        client.close # flush and uncork socket immediately, no keepalive
      end
    rescue => e
      handle_error(client, e)
    ensure
      env["rack.after_reply"].each(&:call) if env
      timeout_handler.finished
    end

    def nuke_listeners!(readers)
      # only called from the worker, ordering is important here
      tmp = readers.dup
      readers.replace([false]) # ensure worker does not continue ASAP
      tmp.each { |io| io.close rescue nil } # break out of IO.select
    end

    # gets rid of stuff the worker has no business keeping track of
    # to free some resources and drops all sig handlers.
    # traps for USR2, and HUP may be set in the after_fork Proc
    # by the user.
    def init_worker_process(worker)
      worker.reset
      worker.register_to_master(@control_socket[1])
      # we'll re-trap :QUIT and :TERM later for graceful shutdown iff we accept clients
      exit_sigs = [ :QUIT, :TERM, :INT ]
      exit_sigs.each { |sig| trap(sig) { exit!(0) } }
      exit!(0) if (@sig_queue & exit_sigs)[0]
      (@queue_sigs - exit_sigs).each { |sig| trap(sig, nil) }
      trap(:CHLD, 'DEFAULT')
      @sig_queue.clear
      proc_name "(gen:#{worker.generation}) worker[#{worker.nr}]"
      @children = nil

      after_worker_fork.call(self, worker) # can drop perms and create listeners
      LISTENERS.each { |sock| sock.close_on_exec = true }

      @config = nil
      @listener_opts = @orig_app = nil
      readers = LISTENERS.dup
      readers << worker
      trap(:QUIT) { nuke_listeners!(readers) }
      trap(:TERM) { nuke_listeners!(readers) }
      readers
    end

    def init_mold_process(mold)
      proc_name "(gen: #{mold.generation}) mold"
      after_mold_fork.call(self, mold)
      readers = [mold]
      trap(:QUIT) { nuke_listeners!(readers) }
      trap(:TERM) { nuke_listeners!(readers) }
      readers
    end

    if Pitchfork.const_defined?(:Waiter)
      def prep_readers(readers)
        Pitchfork::Waiter.prep_readers(readers)
      end
    else
      require_relative 'select_waiter'
      def prep_readers(_readers)
        Pitchfork::SelectWaiter.new
      end
    end

    # runs inside each forked worker, this sits around and waits
    # for connections and doesn't die until the parent dies (or is
    # given a INT, QUIT, or TERM signal)
    def worker_loop(worker)
      readers = init_worker_process(worker)
      waiter = prep_readers(readers)

      ready = readers.dup
      @after_worker_ready.call(self, worker)

      while readers[0]
        begin
          worker.update_deadline(@timeout)
          while sock = ready.shift
            # Pitchfork::Worker#accept_nonblock is not like accept(2) at all,
            # but that will return false
            client = sock.accept_nonblock(exception: false)
            client = false if client == :wait_readable
            if client
              case client
              when Message::PromoteWorker
                spawn_mold(worker.generation)
              when Message
                worker.update(client)
              else
                process_client(client, prepare_timeout(worker))
                @after_request_complete&.call(self, worker)
                worker.increment_requests_count
              end
              worker.update_deadline(@timeout)
            end
          end

          # timeout so we can update .deadline and keep parent from SIGKILL-ing us
          worker.update_deadline(@timeout)

          if @refork_condition && Info.fork_safe? && !worker.outdated?
            if @refork_condition.met?(worker, logger)
              if spawn_mold(worker.generation)
                logger.info("Refork condition met, promoting ourselves")
              end
              @refork_condition.backoff!
            end
          end

          waiter.get_readers(ready, readers, @timeout * 500) # to milliseconds, but halved
        rescue => e
          Pitchfork.log_error(@logger, "listen loop error", e) if readers[0]
        end
      end
    end

    def spawn_mold(current_generation)
      return false unless @promotion_lock.try_lock

      begin
        Pitchfork.fork_sibling do
          mold = Worker.new(nil, pid: Process.pid, generation: current_generation)
          mold.promote!
          mold.start_promotion(@control_socket[1])
          mold_loop(mold)
        end
      rescue
        # HACK: we need to call this on error or on no error, but not on throw
        # hence why we don't use `ensure`
        @promotion_lock.at_fork
        raise
      else
        @promotion_lock.at_fork # We let the spawned mold own the lock
      end
      true
    end

    def mold_loop(mold)
      readers = init_mold_process(mold)
      waiter = prep_readers(readers)
      @promotion_lock.unlock
      ready = readers.dup

      mold.finish_promotion(@control_socket[1])

      while readers[0]
        begin
          mold.update_deadline(@timeout)
          while sock = ready.shift
            # Pitchfork::Worker#accept_nonblock is not like accept(2) at all,
            # but that will return false
            message = sock.accept_nonblock(exception: false)
            case message
            when false
              # no message, keep looping
            when Message::SpawnWorker
              begin
                spawn_worker(Worker.new(message.nr, generation: mold.generation), detach: true)
              rescue => error
                raise BootFailure, error.message
              end
            else
              logger.error("Unexpected mold message #{message.inspect}")
            end
          end

          # timeout so we can .tick and keep parent from SIGKILL-ing us
          mold.update_deadline(@timeout)
          waiter.get_readers(ready, readers, @timeout * 500) # to milliseconds, but halved
        rescue => e
          Pitchfork.log_error(@logger, "mold loop error", e) if readers[0]
        end
      end
    end

    # delivers a signal to a worker and fails gracefully if the worker
    # is no longer running.
    def kill_worker(signal, wpid)
      Process.kill(signal, wpid)
    rescue Errno::ESRCH
      worker = @children.reap(wpid) and worker.close rescue nil
    end

    # delivers a signal to each worker
    def kill_each_child(signal)
      @children.each { |w| kill_worker(signal, w.pid) }
    end

    def soft_kill_each_child(signal)
      @children.each { |worker| worker.soft_kill(signal) }
    end

    # returns an array of string names for the given listener array
    def listener_names(listeners = LISTENERS)
      listeners.map { |io| sock_name(io) }
    end

    def build_app!
      return unless app.respond_to?(:arity)

      self.app = case app.arity
      when 0
        app.call
      when 2
        app.call(nil, self)
      when 1
        app # already a rack app
      end
    end

    def proc_name(tag)
      $0 = ([ File.basename(START_CTX[0]), tag
            ]).concat(START_CTX[:argv]).join(' ')
    end

    def bind_listeners!
      listeners = config[:listeners].dup
      if listeners.empty?
        listeners << Pitchfork::Const::DEFAULT_LISTEN
        @init_listeners << Pitchfork::Const::DEFAULT_LISTEN
        START_CTX[:argv] << "-l#{Pitchfork::Const::DEFAULT_LISTEN}"
      end
      listeners.each { |addr| listen(addr) }
      raise ArgumentError, "no listeners" if LISTENERS.empty?
    end

    def prepare_timeout(worker)
      handler = TimeoutHandler.new(self, worker, @after_worker_timeout)
      handler.timeout_request = SoftTimeout.request(@soft_timeout, handler)
      handler
    end
  end
end
