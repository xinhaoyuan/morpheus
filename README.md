Morpheus
=====

A research project to sandbox and model erlang/otp concurrency using dynamic code re-writing.
The main purpose is for reliable and scalable concurrency testing in fully controlled environment.

Tested on OTP-{20,21}.

Build
-----

    make

Usage
-----

As a research project, the API may change overtime and the document here may become obsolete -- please refer to example code.

We use the term `host` to refer the program running outside of the sandbox and `guest` for the program inside.

All usage of Morpheus starts with the call
```erlang
morpheus_sandbox:start(module(), atom(), [term()], [option()]) -> pid() | {pid(), reference()}
```
which takes the entry function of the sandbox and startup options, and returns the pid of the controller process (with a monitor link if the `monitor` option is proveided).

After the sandbox is started, host usually waits for the sandbox to end with some result, which is passed using the exit reason of the controller process.

Below is the typical host side code for a morpheus-based test, which asserts that the test in the sandbox exits with the `success` atom.

```erlang
{_, MRef} = morpheus_sandbox:start(?MODULE, sandbox_entry, [], [monitor, ...]),
success = receive {'DOWN', MRef, _, _, Reason} -> Reason end
```

Inside the sandbox, the guest performs tests normally as if it is executed without sandboxing.
However, when the entry function is called in the sandbox, __no__ system components are started.
This means the guest has to start them if any are needed as dependencies.
Morpheus provided `morpheus_guest_helper:bootstrap/0` function to start a __single-node__ environment with `kernel` and `stdlib` applications.
With that called, the guest could basically do any testing as it normally would do,
and returns the testing result to the host by `morpheus:exit_with(Reason :: term()) -> none()` function.

So a basic guest test function would look like:

```erlang
sandbox_entry() ->
    morpheus_guest_helper:bootstrap(),
    
    test_body(),
    
    morpheus_guest:exit_with(success).
```

### Testing with Randomized Scheduler

The integration with Firedrill allows reliable and scalable randomized concurrency testing.
To do this, one needs to specify Firedrill options as `{fd_opts, ...}` in the option lists.

Due to the lack of documentation, we list the most important options here:

 - `{scheduler, {SchedName, SchedOpts}}`
 
   Testing using the scheduling algorithm named `SchedName` with options `SchedOpts`.
   Recommended algorithms are `basicpos` and `rw` (stands for random walk).

   The most useful scheduling options are `{seed, SeedTerm}`,
   which is to enforce the scheduler to follow a random sequence decided by `SeedTerm`.
   This is to reliably replay any errors found by the testing.
   Without the `{seed, ...}` option, Firedrill would choose seed randomly and print it to console, so we can further use it to replay.

### Testing with Distributed Erlang Simulation

To test a program with simulated distributed setting.
We need a patched beam VM with specialized BIFs.
The patches for supported OTP versions are in `otp-patches`.

Beside of patched VM,

 - The sandbox must be started with `{node, NodeName}` in the option list,
   and the initial function shall call `morpheus_guest_helper:bootstrap(NodeName)` instead of `morpheus_guest_helper:bootstrap()`.
   The two `NodeName` must match.

 - Other nodes are started with `morpheus_guest_helper:bootstrap_remote(AnotherNodeName)`.
 
### Tracing the Execution

When an error is found, the following options and functions may be handy to understand the execution:

 - Option `trace_send`: print the source process, file location, and the target process when a message is sent.
 - Option `trace_receive`: print the receiver process and file location when a message is received.
 - Option `{trace_from_start, true}`: start tracing once the entry MFA is called.
   Otherwise the tracing is enable only after the function call `morpheus_guest:set_flags([{tracing, true}])` in the guest.
 - Options `verbose_handle` and `verbose_ctl` can be used to print noisy internal information to help debugging.

Examples
-----

Please see the repo https://github.com/xinhaoyuan/morpheus-app-test for examples of testing real applications.

Limitations
-----

 - Simulating distributed settings requires patching Beam VM.

   Patches are in otp-patches (so far only for OTP-{20,21}).

 - External inputs (i.e. ports and NIFs) need to be deterministic given the control of the erlang program.

   For example, we don't support ports that send back random numbers.

 - It only supports fully connected nodes without node-level failure.

   Node failures can be (hopefully) simulated by killing/resetting applications on nodes.

 - Modules created in runtime are not supported yet. (e.g. lager doesn't work in sandbox)

Generally speaking, complete sandboxing is tricky and costly.
There are potentially other holes that change application behaviors unexpectedly and produce false positives.
This often happens due to bad failure handling of simulated API that we mis-interpreted.
We do not guarantee that Morpheus can isolate everything in the sandbox.

License
----

APL 2.0 -- See LICENSE
