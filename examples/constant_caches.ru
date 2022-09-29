require "pitchfork/mem_info"

module App
  CONST_NUM = Integer(ENV.fetch("NUM", 100_000))

  CONST_NUM.times do |i|
    class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
      Const#{i} = Module.new

      def self.lookup_#{i}
        Const#{i}
      end
    RUBY
  end

  class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
    def self.warmup
      #{CONST_NUM.times.map { |i| "lookup_#{i}"}.join("\n")}
    end
  RUBY
end

run lambda { |env|
  meminfo = Pitchfork::MemInfo.new(Process.ppid)
  siblings_pids = File.read("/proc/#{Process.ppid}/task/#{Process.ppid}/children").split
  siblings = siblings_pids.map do |pid|
    Pitchfork::MemInfo.new(pid)
  rescue Errno::ENOENT, Errno::ESRCH # The process just died
    nil
  end.compact

  total_pss = meminfo.pss + siblings.map(&:pss).sum
  self_info = Pitchfork::MemInfo.new(Process.pid)

  body = <<~EOS
    Parent RSS: #{meminfo.rss} kiB
       Own PSS: #{self_info.pss} kiB
     Total PSS: #{total_pss} kiB
  EOS

  App.warmup

  [ 200, { 'content-type' => 'text/plain' }, [ body ] ]
}
