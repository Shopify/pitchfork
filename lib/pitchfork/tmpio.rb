# -*- encoding: binary -*-
# frozen_string_literal: true
# :stopdoc:
require 'tmpdir'

module Pitchfork
  # some versions of Ruby had a broken Tempfile which didn't work
  # well with unlinked files.  This one is much shorter, easier
  # to understand, and slightly faster.
  class TmpIO < File

    # creates and returns a new File object.  The File is unlinked
    # immediately, switched to binary mode, and userspace output
    # buffering is disabled
    def self.new
      path = nil

      # workaround File#path being tainted:
      # https://bugs.ruby-lang.org/issues/14485
      fp = begin
        path = "#{Dir::tmpdir}/#{rand}"
        super(path, RDWR|CREAT|EXCL, 0600)
      rescue Errno::EEXIST
        retry
      end

      unlink(path)
      fp.binmode
      fp.sync = true
      fp
    end

    # pretend we're Tempfile for Rack::TempfileReaper
    alias close! close
  end
end
