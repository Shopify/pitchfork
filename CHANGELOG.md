# Unreleased

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