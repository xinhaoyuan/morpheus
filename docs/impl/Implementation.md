# Instrumentation

Morpheus sandboxes erlang program by shadowing modules into instrumented copy.
Instrumented modules have different name (e.g. "$M$" ++ SomeUniqueId ++ "$" ++ ModuleName).
Initially, the entry module of the function is instrumented, and new modules are incrementally instrumented when they are called in the sandbox.
By doing this, we run instrumented copies of modules in the sandbox.

## Optimization - Whitelisting Safe Modules

Instrumentation has considerable overhead, and we want to get rid of when possible.
One way to reduce the overhead is to ignore instrumenting "safe" module that has detereministic behavior and do not have concurrency interactions.
Morpheus instrumentation ignores a number of modules hard-coded in `morpheus_instrument.erl`.

## Handling NIFs and Ports

By nature Morpheus cannot intercept native code.
Our hope is that most NIFs behave deterministically when the erlang program is under our control.
And Morpheus is not target concurrency involving timing of NIFs.
Thus, our goal is to just make sure the timing of NIFs is deterministic.
This essentially is to handle external messages.
Morpheus handles it by setting timeout after each external calls (NIFs and port operations) to wait for any potential external messages,
and insert those messages into our simulated message queue deterministically.
