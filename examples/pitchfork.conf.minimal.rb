# Minimal sample configuration file for Pitchfork

# listen 2007 # by default Pitchfork listens on port 8080
worker_processes 4 # this should be >= nr_cpus
refork_after [50, 100, 1000]
