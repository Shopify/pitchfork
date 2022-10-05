# -*- encoding: binary -*-

require './test/test_helper'

module Pitchfork
  class TestChildren < Minitest::Test
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

    def test_message_worker_promoted
      worker = Worker.new(0)
      @children.register(worker)
      @children.update(Message::WorkerSpawned.new(0, 42, 0, nil))

      assert_nil @children.mold
      @children.update(Message::WorkerPromoted.new(0, 42, 0))
      assert_predicate worker, :mold?
      assert_same worker, @children.mold
      assert_equal [worker], @children.molds
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

    def test_reap_mold
      worker = Worker.new(0)
      @children.register(worker)
      assert_predicate @children, :pending_workers?

      @children.update(Message::WorkerSpawned.new(0, 42, 0, nil))
      @children.update(Message::WorkerPromoted.new(0, 42, 0))

      assert_equal worker, @children.reap(worker.pid)
      assert_nil @children.reap(worker.pid)
      assert_nil @children.mold
      assert_equal [], @children.molds
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
