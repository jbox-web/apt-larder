require "spectator"
require "crystal-env/spec"

# See: https://gitlab.com/arctic-fox/spectator/-/wikis/Configuration
Spectator.configure do |config|
  config.randomize
  config.profile
end

require "../src/apt-larder"

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
