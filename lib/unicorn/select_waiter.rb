module Unicorn
  # fallback for non-Linux and Linux <4.5 systems w/o EPOLLEXCLUSIVE
  class SelectWaiter # :nodoc:
    def get_readers(ready, readers, timeout_msec) # :nodoc:
      timeout_sec = timeout_msec / 1_000.0
      ret = IO.select(readers, nil, nil, timeout_sec) and ready.replace(ret[0])
    end
  end
end
