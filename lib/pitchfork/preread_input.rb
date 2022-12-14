# -*- encoding: binary -*-

module Pitchfork
  # This middleware is used to ensure input is buffered to memory
  # or disk (depending on size) before the application is dispatched
  # by entirely consuming it (from TeeInput) beforehand.
  #
  # Usage (in config.ru):
  #
  #     require 'pitchfork/preread_input'
  #     if defined?(Pitchfork)
  #       use Pitchfork::PrereadInput
  #     end
  #     run YourApp.new
  class PrereadInput

    # :stopdoc:
    def initialize(app)
      @app = app
    end

    def call(env)
      buf = ""
      input = env["rack.input"]
      if input.respond_to?(:rewind)
        true while input.read(16384, buf)
        input.rewind
      end
      @app.call(env)
    end
    # :startdoc:
  end
end
