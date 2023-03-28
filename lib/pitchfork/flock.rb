require 'tempfile'

module Pitchfork
  class Flock
    Error = Class.new(StandardError)

    def initialize(name)
      @name = name
      @file = Tempfile.create([name, '.lock'])
      @file.write("#{Process.pid}\n")
      @file.flush
      @owned = false
    end

    def at_fork
      @owned = false
      @file.close
      @file = File.open(@file.path, "w")
      nil
    end

    def unlink
      File.unlink(@file.path)
    rescue Errno::ENOENT
      false
    end

    def try_lock
      raise Error, "Pitchfork::Flock(#{@name}) trying to lock an already owned lock" if @owned

      if @file.flock(File::LOCK_EX | File::LOCK_NB)
        @owned = true
      else
        false
      end
    end

    def unlock
      raise Error, "Pitchfork::Flock(#{@name}) trying to unlock a non-owned lock" unless @owned

      begin
        if @file.flock(File::LOCK_UN)
          @owned = false
          true
        else
          false
        end
      end
    end
  end
end
