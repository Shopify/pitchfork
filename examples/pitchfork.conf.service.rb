# frozen_string_literal: true
# Minimal sample configuration file for Pitchfork

# listen 2007 # by default Pitchfork listens on port 8080
worker_processes 4 # this should be >= nr_cpus
refork_after [50, 100, 1000]

service_thread = nil
service_shutdown = false

before_service_worker_ready do |server, service|
  service_thread = Thread.new do
    server.logger.info "Service: start"
    count = 1
    until service_shutdown
      server.logger.info "Service: ping count=#{count}"
      count += 1
      sleep 1
    end
  end
end

before_service_worker_exit do |server, service|
  server.logger.info "Service: shutting down"
  service_shutdown = true
  service_thread&.join(2)
end
