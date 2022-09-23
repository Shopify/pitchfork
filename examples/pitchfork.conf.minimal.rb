# Minimal sample configuration file for Pitchfork

listen 2007 # by default Pitchfork listens on port 8080
worker_processes 4 # this should be >= nr_cpus
stderr_path "/path/to/app/shared/log/pitchfork.log"
stdout_path "/path/to/app/shared/log/pitchfork.log"
