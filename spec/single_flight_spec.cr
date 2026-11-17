require "./spec_helper"

Spectator.describe AptLarder::SingleFlight do
  subject(sf) { AptLarder::SingleFlight.new }

  # Receives from *channel*, failing the example when nothing arrives within
  # two seconds: a fiber left blocked must not hang the suite.
  private def receive_or_fail(channel : Channel(Nil)) : Nil
    select
    when channel.receive
    when timeout(2.seconds)
      fail "a fiber was still blocked after 2 seconds"
    end
  end

  describe "#waiters" do
    it "is 0 for a key with no flight in progress" do
      expect(sf.waiters("key")).to eq(0)
    end

    it "counts the callers that joined the flight in progress, and drops to 0 once it ends" do
      leader_started = Channel(Nil).new
      release = Channel(Nil).new
      done = Channel(Nil).new(3)

      spawn do
        sf.run("key") do
          leader_started.send(nil)
          release.receive
        end
        done.send(nil)
      end
      leader_started.receive
      during_leader_alone = sf.waiters("key")

      2.times do
        spawn do
          sf.run("key") { }
          done.send(nil)
        end
      end
      wait_until("both waiters joined the flight") { sf.waiters("key") == 2 }
      other_key = sf.waiters("other")

      release.send(nil)
      3.times { receive_or_fail(done) }

      expect(during_leader_alone).to eq(0)
      expect(other_key).to eq(0)
      expect(sf.waiters("key")).to eq(0)
    end
  end

  describe "#run" do
    it "executes the block" do
      executed = false
      sf.run("key") { executed = true }
      expect(executed).to be_true
    end

    it "can be reused after completion" do
      count = 0
      sf.run("key") { count += 1 }
      sf.run("key") { count += 1 }
      expect(count).to eq(2)
    end

    # Both examples below hold the leader inside its block on a channel the
    # test releases, so what the waiters do in the meantime is observed rather
    # than inferred from a delay.

    it "makes concurrent callers wait for the leader without running their block" do
      leader_started = Channel(Nil).new
      release = Channel(Nil).new
      done = Channel(Nil).new(3)
      leader_runs = Atomic(Int32).new(0)
      waiter_runs = Atomic(Int32).new(0)
      waiters_returned = Atomic(Int32).new(0)

      spawn do
        sf.run("key") do
          leader_runs.add(1)
          leader_started.send(nil)
          release.receive
        end
        done.send(nil)
      end
      leader_started.receive

      2.times do
        spawn do
          sf.run("key") { waiter_runs.add(1) }
          waiters_returned.add(1)
          done.send(nil)
        end
      end
      # Both waiters have joined the flight: from here on, they cannot run
      # their block whatever happens to the leader.
      wait_until("both waiters joined the flight") { sf.waiters("key") == 2 }
      returned_while_leader_ran = waiters_returned.get

      release.send(nil)
      3.times { receive_or_fail(done) }

      expect(returned_while_leader_ran).to eq(0)
      expect(waiters_returned.get).to eq(2)
      expect(leader_runs.get).to eq(1)
      expect(waiter_runs.get).to eq(0)
    end

    it "releases the waiters when the leader's block raises, and raises only in the leader" do
      leader_started = Channel(Nil).new
      release = Channel(Nil).new
      done = Channel(Nil).new(3)
      leader_error = nil
      waiter_errors = Atomic(Int32).new(0)
      waiter_runs = Atomic(Int32).new(0)
      waiters_returned = Atomic(Int32).new(0)

      spawn do
        begin
          sf.run("key") do
            leader_started.send(nil)
            release.receive
            raise "boom"
          end
        rescue ex
          leader_error = ex.message
        end
        done.send(nil)
      end
      leader_started.receive

      2.times do
        spawn do
          begin
            sf.run("key") { waiter_runs.add(1) }
            waiters_returned.add(1)
          rescue
            waiter_errors.add(1)
          end
          done.send(nil)
        end
      end
      # Both waiters have joined the flight: from here on, they cannot run
      # their block whatever happens to the leader.
      wait_until("both waiters joined the flight") { sf.waiters("key") == 2 }
      returned_while_leader_ran = waiters_returned.get

      release.send(nil)
      # A leader that left its waiters blocked fails here instead of hanging.
      3.times { receive_or_fail(done) }

      expect(returned_while_leader_ran).to eq(0)
      expect(leader_error).to eq("boom")
      expect(waiters_returned.get).to eq(2)
      expect(waiter_errors.get).to eq(0)
      expect(waiter_runs.get).to eq(0)
    end

    it "runs blocks independently for different keys" do
      call_count = 0
      mutex = Mutex.new
      done = Channel(Nil).new

      ["k1", "k2", "k3"].each do |key|
        spawn do
          sf.run(key) { mutex.synchronize { call_count += 1 } }
          done.send(nil)
        end
      end

      3.times { done.receive }
      expect(call_count).to eq(3)
    end
  end
end
