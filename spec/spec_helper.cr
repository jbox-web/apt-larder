require "spectator"
require "crystal-env/spec"
require "file_utils"

private SPEC_TMP_PREFIX = "apt-larder-spec-"

# Every scratch directory the suite creates lives under this single root, so a
# failing example — whose per-example cleanup never runs — cannot scatter
# leftovers across the system temp directory. Keyed by PID so two concurrent
# runs do not delete each other's files.
SPEC_TMP_ROOT = File.join(Dir.tempdir, "#{SPEC_TMP_PREFIX}#{Process.pid}")

# Reclaims the roots of runs that are over, at startup rather than at the end.
#
# End-of-suite cleanup cannot work here, and not for want of an entry point:
# Spectator calls `parent.call_after_all` only after `call_around_each` returns
# (example.cr:132), so a failed expectation raises past it and no after_suite
# hook ever fires — precisely on the runs that leave scratch behind. `at_exit`
# is no better: Spectator runs the suite from an at_exit handler that calls
# `exit(1)` on failure (spectator.cr:43), and Crystal skips the handlers that
# have not run yet once one of them exits.
#
# Purging at startup sidesteps both. A failing run leaves exactly one directory
# behind, under a predictable name, reclaimed by the next run. Roots whose
# process is still alive are left alone so concurrent runs do not collide.
Dir.glob(File.join(Dir.tempdir, "#{SPEC_TMP_PREFIX}*")).each do |path|
  pid = File.basename(path).lchop(SPEC_TMP_PREFIX).to_i?
  next unless pid
  next if pid == Process.pid || Process.exists?(pid)
  FileUtils.rm_rf(path)
end

# See: https://gitlab.com/arctic-fox/spectator/-/wikis/Configuration
Spectator.configure do |config|
  config.randomize
  config.profile
end

require "../src/apt-larder"

# Returns a unique scratch directory path under `SPEC_TMP_ROOT`.
# The directory itself is not created — callers that need it on disk create it,
# as `Cache` does.
def spec_tmp_dir(prefix : String) : String
  File.join(SPEC_TMP_ROOT, "#{prefix}-#{Random::Secure.hex(4)}")
end

# Temporarily sets environment variables for the duration of the block,
# restoring original values (including nil) afterwards.
# See: https://github.com/crystal-lang/crystal/issues/16449
# See: https://github.com/crystal-lang/crystal/blob/master/spec/support/env.cr
def with_env(values : Hash(String, String), &)
  old_values = {} of String => String?
  begin
    values.each do |key, value|
      old_values[key] = ENV[key]?
      ENV[key] = value
    end
    yield
  ensure
    old_values.each do |key, old_value|
      if old_value
        ENV[key] = old_value
      else
        ENV.delete(key)
      end
    end
  end
end
