require "./spec_helper"

Spectator.describe AptLarder::SingleFlight do
  subject(sf) { AptLarder::SingleFlight.new }

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

    it "deduplicates concurrent calls for the same key" do
      call_count = 0
      mutex = Mutex.new
      done = Channel(Nil).new

      3.times do
        spawn do
          sf.run("key") do
            mutex.synchronize { call_count += 1 }
            sleep 20.milliseconds
          end
          done.send(nil)
        end
      end

      3.times { done.receive }
      expect(call_count).to eq(1)
    end

    it "unblocks waiters when the leader's block raises" do
      done = Channel(Nil).new
      leader_started = Channel(Nil).new

      # Leader signals it has started, then raises after a short pause so
      # waiters have time to join before the channel is closed by ensure.
      spawn do
        begin
          sf.run("key") do
            leader_started.send(nil)
            sleep 20.milliseconds
            raise "boom"
          end
        rescue
        end
        done.send(nil)
      end

      leader_started.receive
      2.times { spawn { sf.run("key") { }; done.send(nil) } }

      # All three must complete — a deadlock here would hang the test forever.
      3.times { done.receive }
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
