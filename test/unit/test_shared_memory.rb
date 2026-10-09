# frozen_string_literal: true
require 'test_helper'

module Pitchfork
  class TestSharedMemory < Test
    setup do
      @page = MemoryPage.new(MemoryPage::SLOTS)
    end

    teardown do
      @page.close
    end

    def test_memory_page_write_read
      assert_equal 0, @page[0]
      @page[0] = 12
      assert_equal 12, @page[0]

      assert_equal 0, @page[1]
      @page[1] = 24
      assert_equal 24, @page[1]
    end

    def test_memory_page_file_descriptor
      assert_operator @page.fileno, :>, 0
    end

    def test_double_close
      refute_predicate @page, :closed?
      @page.close
      assert_predicate @page, :closed?
      @page.close
      assert_predicate @page, :closed?
    end

    def test_read_after_close
      @page[0] = 12
      assert_equal 12, @page[0]

      @page.close

      assert_raises StandardError do
        @page[0]
      end
    end

    def test_for_fd_exec
      assert_predicate @page, :close_on_exec?
      @page.close_on_exec = false

      file = Tempfile.create([name, '.rb'])
      file.write(<<~'RUBY')
        require "pitchfork"
        page = Pitchfork::MemoryPage.for_fd(Integer(ARGV.first))
        if page[0] == 1234
          page[0] = 4321
        else
          exit 1
        end
      RUBY
      file.close

      assert_equal 0, @page[0]

      in_child do
        @page[0] = 1234
        Process.exec(RbConfig.ruby, file.path, @page.fileno.to_s)
      end

      assert_equal 4321, @page[0]
    end

    def test_close_in_child
      fd = @page.fileno
      page_clone = MemoryPage.for_fd(fd)
      page_clone.close

      # The fd was already closed
      # We should avoid this ever happening
      assert_raises Errno::EBADF do
        @page.close
      end
    end

    def test_close_on_exec
      assert_predicate @page, :close_on_exec?

      file = Tempfile.create([name, '.rb'])
      file.write(<<~'RUBY')
        require "pitchfork"
        begin
          Pitchfork::MemoryPage.for_fd(Integer(ARGV.first))
        rescue Errno::EBADF
          exit 0
        else
          exit 1
        end
      RUBY
      file.close

      assert_equal 0, @page[0]

      assert system(RbConfig.ruby, file.path, @page.fileno.to_s)
    end

    def test_current_generation
      SharedMemory.current_generation = 1
      assert_equal 1, SharedMemory.current_generation
      in_child do
        SharedMemory.current_generation += 1
      end
      assert_equal 2, SharedMemory.current_generation
    end

    def test_mold_state
      mold_state = SharedMemory.mold_state
      mold_state.deadline = 24
      mold_state.ready = false

      assert_equal 24, mold_state.deadline
      assert_equal false, mold_state.ready?

      in_child do
        mold_state.deadline += 1
        mold_state.ready = !mold_state.ready?
      end

      assert_equal 25, mold_state.deadline
      assert_equal true, mold_state.ready?
    end

    private

    def in_child(&block)
      pid = fork(&block)
      _, status = Process.waitpid2(pid)
      assert_predicate status, :success?
    end
  end
end
