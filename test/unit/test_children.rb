# -*- encoding: binary -*-
# frozen_string_literal: true
require 'test_helper'

module Pitchfork
  class TestChildren < Test
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
      pipe = IO.pipe.last
      worker = Worker.new(0)
      @children.register(worker)
      assert_predicate @children, :pending_workers?
      assert @children.nr_alive?(0)

      @children.update(Message::WorkerSpawned.new(0, 42, 0, 0, pipe))
      refute_predicate @children, :pending_workers?
      assert @children.nr_alive?(0), @children.inspect
      assert_equal 42, worker.pid
      assert_equal [worker], @children.workers
    end

    def test_restarting_workers_count_tracks_worker_lifecycle
      assert_equal 0, @children.restarting_workers_count

      UNIXSocket.pair do |_reader, writer|
        worker = Worker.new(0)
        @children.register(worker)
        assert_equal 1, @children.restarting_workers_count

        @children.update(Message::WorkerSpawned.new(0, 42, 0, writer))
        refute_predicate @children, :pending_workers?
        assert_equal 1, @children.restarting_workers_count

        worker.ready = true
        assert_equal 0, @children.restarting_workers_count

        assert worker.soft_kill(:TERM)
        assert_equal 1, @children.restarting_workers_count

        worker.ready = false
        assert_equal 1, @children.restarting_workers_count

        @children.reap(worker.pid)
        assert_equal 0, @children.restarting_workers_count
      end
    end

    def test_restarting_workers_count_includes_ready_workers_pending_registration
      worker = Worker.new(0)
      @children.register(worker)

      worker.ready = true
      assert_equal 1, @children.restarting_workers_count
    end

    def test_restarting_workers_count_counts_each_unavailable_worker_once
      sockets = Array.new(3) { UNIXSocket.pair }
      workers = Array.new(4) do |nr|
        worker = Worker.new(nr)
        @children.register(worker)
        worker
      end
      sockets.each_with_index do |(_, writer), index|
        nr = index + 1
        @children.update(Message::WorkerSpawned.new(nr, 42 + nr, 0, writer))
      end

      workers[2].ready = workers[3].ready = true
      assert workers[2].soft_kill(:TERM)
      assert_equal 3, @children.restarting_workers_count

      workers[1].ready = true
      assert_equal 2, @children.restarting_workers_count

      workers[2].ready = false
      assert_equal 2, @children.restarting_workers_count

      @children.abandon(workers[0])
      assert_equal 1, @children.restarting_workers_count

      @children.reap(workers[2].pid)
      assert_equal 0, @children.restarting_workers_count
    ensure
      sockets&.flatten&.each(&:close)
    end

    def test_message_mold_spawned
      pipe = IO.pipe.last
      assert_nil @children.mold
      @children.update(Message::MoldSpawned.new(nil, 42, 1, 0, pipe))

      assert_nil @children.mold
      assert_equal 0, @children.molds.size
      assert_predicate @children, :pending_promotion?
      assert_equal [], @children.workers
      assert_equal 0, @children.workers_count
    end

    def test_message_mold_ready
      pipe = IO.pipe.last
      assert_nil @children.mold
      @children.update(Message::MoldSpawned.new(nil, 42, 1, 0, pipe))
      mold = @children.update(Message::MoldReady.new(42))

      assert_equal mold, @children.mold
      assert_equal [mold], @children.molds
      refute_predicate @children, :pending_promotion?
      assert_equal [], @children.workers
      assert_equal 0, @children.workers_count
    end

    def test_reap_worker
      pipe = IO.pipe.last
      worker = Worker.new(0)
      @children.register(worker)
      assert_predicate @children, :pending_workers?

      @children.update(Message::WorkerSpawned.new(0, 42, 0, 0, pipe))

      assert_equal worker, @children.reap(worker.pid)
      assert_nil @children.reap(worker.pid)
    end

    def test_reap_old_molds
      pipe = IO.pipe.last
      assert_nil @children.mold
      @children.update(Message::MoldSpawned.new(nil, 24, 0, 0, pipe))
      @children.update(Message::MoldReady.new(24))

      first_mold = @children.mold
      refute_nil first_mold
      assert_equal 24, first_mold.pid

      @children.update(Message::MoldSpawned.new(nil, 42, 1, 0, pipe))
      @children.update(Message::MoldReady.new(42))
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

    def test_dump_load
      pipe = Pitchfork.socketpair.last
      worker = Worker.new(0)
      @children.register(worker)
      assert_predicate @children, :pending_workers?
      assert @children.nr_alive?(0)

      assert_equal(@children.dump, Children.load(@children.dump).dump)

      @children = assert_roundtrip(@children)
      worker = @children.workers.first

      assert_predicate @children, :pending_workers?

      @children.update(Message::WorkerSpawned.new(0, 42, 0, 0, pipe))
      refute_predicate @children, :pending_workers?
      assert @children.nr_alive?(0), @children.inspect
      assert_equal 42, worker.pid
      assert_equal [worker], @children.workers

      @children = assert_roundtrip(@children)
      worker = @children.workers.first

      refute_predicate @children, :pending_workers?
      assert @children.nr_alive?(0), @children.inspect
      assert_equal 42, worker.pid
      assert_equal [worker], @children.workers

      pipe = Pitchfork.socketpair.last
      @children.update(Message::MoldSpawned.new(nil, 42, 1, 0, pipe))
      @children.update(Message::MoldReady.new(42))

      assert_not_nil @children.mold
      @children = assert_roundtrip(@children)

      pipe = Pitchfork.socketpair.last
      service = Worker.new(nil, service: true)
      @children.register_service(service)
      @children.update(Message::ServiceSpawned.new(48, 1, 0, pipe))
      @children.update(Message::ServiceReady.new(48))

      @children = assert_roundtrip(@children)
      assert_not_nil @children.service
    end

    private

    def assert_roundtrip(children)
      data = children.dump
      cloned_children = Children.load(data)
      assert_equal(data.to_set, cloned_children.dump.to_set)
      cloned_children
    end
  end
end
