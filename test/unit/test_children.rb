# -*- encoding: binary -*-
require 'test_helper'

module Pitchfork
  class TestChildren < Pitchfork::Test
    def setup
      @children = Children.new
    end

    def test_register
      refute_predicate @children, :pending_workers?
      refute @children.nr_alive?(0)
      worker = Worker.new(0)

      @children.register(worker)
      assert_predicate @children, :pending_workers?
      assert @children.nr_alive?(0)
    end

    def test_message_worker_spawned
      worker = Worker.new(0)
      @children.register(worker)
      assert_predicate @children, :pending_workers?

      @children.update(Message::WorkerSpawned.new(0, 42, 0, nil))
      refute_predicate @children, :pending_workers?
      assert_equal 42, worker.pid
      assert_equal [worker], @children.workers
    end

    def test_message_mold_spawned
      assert_nil @children.mold
      @children.update(Message::MoldSpawned.new(nil, 42, 1, nil))

      assert_nil @children.mold
      assert_equal 0, @children.molds.size
      assert_predicate @children, :pending_promotion?
      assert_equal [], @children.workers
      assert_equal 0, @children.workers_count
    end

    def test_message_mold_ready
      assert_nil @children.mold
      @children.update(Message::MoldSpawned.new(nil, 42, 1, nil))
      mold = @children.update(Message::MoldReady.new(nil, 42, 1))

      assert_equal mold, @children.mold
      assert_equal [mold], @children.molds
      refute_predicate @children, :pending_promotion?
      assert_equal [], @children.workers
      assert_equal 0, @children.workers_count
    end

    def test_reap_worker
      worker = Worker.new(0)
      @children.register(worker)
      assert_predicate @children, :pending_workers?

      @children.update(Message::WorkerSpawned.new(0, 42, 0, nil))

      assert_equal worker, @children.reap(worker.pid)
      assert_nil @children.reap(worker.pid)
    end

    def test_reap_old_molds
      assert_nil @children.mold
      @children.update(Message::MoldSpawned.new(nil, 24, 0, nil))
      @children.update(Message::MoldReady.new(nil, 24, 0))

      first_mold = @children.mold
      refute_nil first_mold
      assert_equal 24, first_mold.pid

      @children.update(Message::MoldSpawned.new(nil, 42, 1, nil))
      @children.update(Message::MoldReady.new(nil, 42, 1))
      second_mold = @children.mold
      refute_nil second_mold
      assert_equal 42, second_mold.pid

      assert_equal [first_mold, second_mold], @children.molds

      @children.reap(24)

      assert_equal [second_mold], @children.molds
      assert_equal second_mold, @children.mold
    end

    def test_reap_pending_mold
      mold = Worker.new(nil)
      @children.register_mold(mold)
      assert_predicate @children, :pending_workers?

      assert_equal mold, @children.reap(mold.pid)
      refute_predicate @children, :pending_workers?
      assert_nil @children.mold
      assert_equal [], @children.molds
      assert_nil @children.reap(mold.pid)
    end
  end
end
