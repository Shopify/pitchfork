# Unreleased

- Implement `after_worker_hard_timeout` callback.

# 0.5.0

- Added a soft timeout in addition to the historical Unicorn hard timeout.
  On soft timeout, the `after_worker_timeout` callback is invoked.
- Implement `after_request_complete` callback.

# 0.4.1

- Avoid a Rack 3 deprecation warning.
- Fix handling on non-ASCII cookies.
- Log unknown process being reaped at INFO level.

# 0.4.0

- Preserve the current thread when reforking.

# 0.3.0

- Renamed `after_promotion` in `after_mold_fork`.
- Renamed `after_fork` in `after_worker_fork`.
- Backoff 10s after every mold spawning attempt.
- Spawn mold from workers instead of promoting workers (#42).

# 0.2.0

- Remove default middlewares.
- Refork indefinitely when `refork_after` is set, unless the last element is `false`.
- Remove `mold_selector`. The promotion logic has been moved inside workers (#38).
- Add the `after_promotion` callback.
- Removed the `before_fork` callback.
- Fork workers and molds with a clean stack to allow more generations. (#30)

# 0.1.2

- Improve Ruby 3.2 and Rack 3 compatibility.

# 0.1.1

- Fix `extconf.rb` to move the extension in the right place on gem install. (#18)

# 0.1.0

Initial release