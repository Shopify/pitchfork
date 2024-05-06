# Unicorn Migration Guide

While Pitchfork started out as a patch on top of Unicorn, many Unicorn features
that don't make sense in containerized environments were removed to simplify the codebase.

This guide is intended to cover the most common changes you need to make to your configuration
in order to make the switch.

> [!NOTE]
> This document doesn't contain every incompatibility with Unicorn. If you encounter
additional incompatibilities, please open an Issue or a Pull Request to add your findings.

* The configurations `user`, `working_directory`, `stderr_path`, `stdout_path`, and `pid`
have been removed without replacement. Pitchfork is designed for modern deployment strategies
like Docker and Systemd, as such the responsibility for this functionality is delegated to
these systems.

* The configuration `preload_app` has been removed without replacement. Pitchfork will always behave
as if it is set to `true`.

* The Signal `USR2` has been repurposed for reforking. Remove `ExecReload` from your Sytemd unit
file, if it contains it. Reloading is not a supported feature of Pitchfork.

* The configuration `after_fork` has been split between `after_worker_fork` and `after_mold_fork`.

* If you use `unicorn-worker-killer` or similar gems, you will need to implement this functionally yourself since
there is no `pitchfork-worker-killer`. Changes to Pitchfork internals make this a pretty painless
ordeal, you can check out the following GitHub issue to get started: https://github.com/Shopify/pitchfork/issues/92

## Reforking

[Reforking](REFORKING.md) is Pitchfork's main selling point. Give [Refork Safety](FORK_SAFETY.md#refork-safety) a read to understand
if your application may be compatible. [Enabling reforking](CONFIGURATION.md#refork_after) will give you memory savings above what Unicorn
is able to offer with its forking model.
