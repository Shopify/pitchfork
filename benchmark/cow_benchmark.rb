#!/usr/bin/env ruby
require "net/http"

app_path = File.expand_path('../examples/constant_caches.ru', __dir__)

puts "Booting server..."
pid = Process.spawn(*ARGV, app_path, out: File::NULL, err: File::NULL)
sleep 5
app_url = "http://localhost:#{ENV.fetch('PORT')}/"
puts "Warming the app with ab..."
system("ab", "-c", "4", "-n", "500", app_url, out: File::NULL, err: File::NULL)
sleep 3
puts "Memory Usage:"
puts Net::HTTP.get(URI(app_url))

Process.kill("INT", pid)
Process.wait