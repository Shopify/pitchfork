# -*- encoding: binary -*-
require 'logger'

module Pitchfork
  # Implements a simple DSL for configuring a pitchfork server.
  #
  # See https://github.com/Shopify/pitchfork/tree/master/examples/pitchfork.conf.rb and
  # https://github.com/Shopify/pitchfork/tree/master/examples/pitchfork.conf.minimal.rb
  # example configuration files.
  #
  # See the docs/TUNING.md document for more information on tuning pitchfork.
  class Configurator
    include Pitchfork

    # :stopdoc:
    attr_accessor :set, :config_file, :after_load

    # used to stash stuff for deferred processing of cli options in
    # config.ru.  Do not rely on
    # this being around later on...
    RACKUP = {
      :host => Pitchfork::Const::DEFAULT_HOST,
      :port => Pitchfork::Const::DEFAULT_PORT,
      :set_listener => false,
      :options => { :listeners => [] }
    }

    # Default settings for Pitchfork
    default_logger = Logger.new($stderr)
    default_logger.formatter = Logger::Formatter.new
    default_logger.progname = "[Pitchfork]"

    DEFAULTS = {
      :soft_timeout => 20,
      :cleanup_timeout => 2,
      :timeout => 22,
      :logger => default_logger,
      :worker_processes => 1,
      :after_worker_fork => lambda { |server, worker|
        server.logger.info("worker=#{worker.nr} gen=#{worker.generation} pid=#{$$} spawned")
      },
      :after_mold_fork => lambda { |server, worker|
        server.logger.info("mold gen=#{worker.generation} pid=#{$$} spawned")
      },
      :before_worker_exit => nil,
      :after_worker_exit => lambda { |server, worker, status|
        m = if worker.nil?
          "repead unknown process (#{status.inspect})"
        elsif worker.mold?
          "mold pid=#{worker.pid rescue 'unknown'} gen=#{worker.generation rescue 'unknown'} reaped (#{status.inspect})"
        else
          "worker=#{worker.nr rescue 'unknown'} pid=#{worker.pid rescue 'unknown'} gen=#{worker.generation rescue 'unknown'} reaped (#{status.inspect})"
        end
        if status.success?
          server.logger.info(m)
        else
          server.logger.error(m)
        end
      },
      :after_worker_ready => lambda { |server, worker|
        server.logger.info("worker=#{worker.nr} gen=#{worker.generation} ready")
      },
      :after_worker_timeout => nil,
      :after_worker_hard_timeout => nil,
      :after_request_complete => nil,
      :early_hints => false,
      :refork_condition => nil,
      :check_client_connection => false,
      :rewindable_input => true,
      :client_body_buffer_size => Pitchfork::Const::MAX_BODY,
    }
    #:startdoc:

    def initialize(defaults = {}) #:nodoc:
      self.set = Hash.new(:unset)
      @use_defaults = defaults.delete(:use_defaults)
      self.config_file = defaults.delete(:config_file)

      set.merge!(DEFAULTS) if @use_defaults
      defaults.each { |key, value| self.__send__(key, value) }
      Hash === set[:listener_opts] or
          set[:listener_opts] = Hash.new { |hash,key| hash[key] = {} }
      Array === set[:listeners] or set[:listeners] = []
      load(false)
    end

    def load(merge_defaults = true) #:nodoc:
      if merge_defaults && @use_defaults
        set.merge!(DEFAULTS) if @use_defaults
      end
      instance_eval(File.read(config_file), config_file) if config_file

      parse_rackup_file

      RACKUP[:set_listener] and
        set[:listeners] << "#{RACKUP[:host]}:#{RACKUP[:port]}"
    end

    def commit!(server, options = {}) #:nodoc:
      skip = options[:skip] || []
      if ready_pipe = RACKUP.delete(:ready_pipe)
        server.ready_pipe = ready_pipe
      end
      if set[:check_client_connection]
        set[:listeners].each do |address|
          if set[:listener_opts][address][:tcp_nopush] == true
            raise ArgumentError,
              "check_client_connection is incompatible with tcp_nopush:true"
          end
        end
      end
      set.each do |key, value|
        value == :unset and next
        skip.include?(key) and next
        server.__send__("#{key}=", value)
      end
    end

    def [](key) # :nodoc:
      set[key]
    end

    def logger(obj)
      %w(debug info warn error fatal).each do |m|
        obj.respond_to?(m) and next
        raise ArgumentError, "logger=#{obj} does not respond to method=#{m}"
      end

      set[:logger] = obj
    end

    def after_worker_fork(*args, &block)
      set_hook(:after_worker_fork, block_given? ? block : args[0])
    end

    def after_mold_fork(*args, &block)
      set_hook(:after_mold_fork, block_given? ? block : args[0])
    end

    def after_worker_ready(*args, &block)
      set_hook(:after_worker_ready, block_given? ? block : args[0])
    end

    def after_worker_timeout(*args, &block)
      set_hook(:after_worker_timeout, block_given? ? block : args[0], 3)
    end

    def after_worker_hard_timeout(*args, &block)
      set_hook(:after_worker_hard_timeout, block_given? ? block : args[0], 2)
    end

    def before_worker_exit(*args, &block)
      set_hook(:before_worker_exit, block_given? ? block : args[0], 2)
    end

    def after_worker_exit(*args, &block)
      set_hook(:after_worker_exit, block_given? ? block : args[0], 3)
    end

    def after_request_complete(*args, &block)
      set_hook(:after_request_complete, block_given? ? block : args[0])
    end

    def timeout(seconds, cleanup: 2)
      soft_timeout = set_int(:soft_timeout, seconds, 3)
      cleanup_timeout = set_int(:cleanup_timeout, cleanup, 2)
      set_int(:timeout, soft_timeout + cleanup_timeout, 5)
    end

    def worker_processes(nr)
      set_int(:worker_processes, nr, 1)
    end

    def early_hints(bool)
      set_bool(:early_hints, bool)
    end

    # sets listeners to the given +addresses+, replacing or augmenting the
    # current set.
    def listeners(addresses) # :nodoc:
      Array === addresses or addresses = Array(addresses)
      addresses.map! { |addr| expand_addr(addr) }
      set[:listeners] = addresses
    end

    def listen(address, options = {})
      address = expand_addr(address)
      if String === address
        [ :umask, :backlog, :sndbuf, :rcvbuf, :tries ].each do |key|
          value = options[key] or next
          Integer === value or
            raise ArgumentError, "not an integer: #{key}=#{value.inspect}"
        end
        [ :tcp_nodelay, :tcp_nopush, :ipv6only, :reuseport ].each do |key|
          (value = options[key]).nil? and next
          TrueClass === value || FalseClass === value or
            raise ArgumentError, "not boolean: #{key}=#{value.inspect}"
        end
        unless (value = options[:delay]).nil?
          Numeric === value or
            raise ArgumentError, "not numeric: delay=#{value.inspect}"
        end
        set[:listener_opts][address].merge!(options)
      end

      set[:listeners] << address
    end

    def rewindable_input(bool)
      set_bool(:rewindable_input, bool)
    end

    def client_body_buffer_size(bytes)
      set_int(:client_body_buffer_size, bytes, 0)
    end

    def check_client_connection(bool)
      set_bool(:check_client_connection, bool)
    end

    # Defines the number of requests per-worker after which a new generation
    # should be spawned.
    #
    # +false+ can be used to mark a final generation, otherwise the last request
    # count is re-used indefinitely.
    #
    # example:
    #.  refork_after [50, 100, 1000]
    #.  refork_after [50, 100, 1000, false]
    #
    # Note that reforking is only available on Linux. Other Unix-like systems
    # don't have this capability.
    def refork_after(limits)
      set[:refork_condition] = ReforkCondition::RequestsCount.new(limits)
    end

    # expands "unix:path/to/foo" to a socket relative to the current path
    # expands pathnames of sockets if relative to "~" or "~username"
    # expands "*:port and ":port" to "0.0.0.0:port"
    def expand_addr(address) #:nodoc:
      return "0.0.0.0:#{address}" if Integer === address
      return address unless String === address

      case address
      when %r{\Aunix:(.*)\z}
        File.expand_path($1)
      when %r{\A~}
        File.expand_path(address)
      when %r{\A(?:\*:)?(\d+)\z}
        "0.0.0.0:#$1"
      when %r{\A\[([a-fA-F0-9:]+)\]\z}, %r/\A((?:\d+\.){3}\d+)\z/
        canonicalize_tcp($1, 80)
      when %r{\A\[([a-fA-F0-9:]+)\]:(\d+)\z}, %r{\A(.*):(\d+)\z}
        canonicalize_tcp($1, $2.to_i)
      else
        address
      end
    end

  private
    def set_int(var, n, min) #:nodoc:
      Integer === n or raise ArgumentError, "not an integer: #{var}=#{n.inspect}"
      n >= min or raise ArgumentError, "too low (< #{min}): #{var}=#{n.inspect}"
      set[var] = n
    end

    def canonicalize_tcp(addr, port)
      packed = Socket.pack_sockaddr_in(port, addr)
      port, addr = Socket.unpack_sockaddr_in(packed)
      addr.include?(':') ? "[#{addr}]:#{port}" : "#{addr}:#{port}"
    end

    def set_path(var, path) #:nodoc:
      case path
      when NilClass, String
        set[var] = path
      else
        raise ArgumentError
      end
    end

    def check_bool(var, bool) # :nodoc:
      case bool
      when true, false
        return bool
      end
      raise ArgumentError, "#{var}=#{bool.inspect} not a boolean"
    end

    def set_bool(var, bool) #:nodoc:
      set[var] = check_bool(var, bool)
    end

    def set_hook(var, my_proc, req_arity = 2) #:nodoc:
      case my_proc
      when Proc
        arity = my_proc.arity
        (arity == req_arity) or \
          raise ArgumentError,
                "#{var}=#{my_proc.inspect} has invalid arity: " \
                "#{arity} (need #{req_arity})"
      when NilClass
        my_proc = DEFAULTS[var]
      else
        raise ArgumentError, "invalid type: #{var}=#{my_proc.inspect}"
      end
      set[var] = my_proc
    end

    # This only parses the embedded switches in .ru files
    # (for "rackup" compatibility)
    def parse_rackup_file # :nodoc:
      ru = RACKUP[:file] or return # we only return here in unit tests

      # :rails means use (old) Rails autodetect
      if ru == :rails
        File.readable?('config.ru') or return
        ru = 'config.ru'
      end

      File.readable?(ru) or
        raise ArgumentError, "rackup file (#{ru}) not readable"

      # it could be a .rb file, too, we don't parse those manually
      ru.end_with?('.ru') or return

      /^#\\(.*)/ =~ File.read(ru) or return
      RACKUP[:optparse].parse!($1.split(/\s+/))
    end
  end
end
