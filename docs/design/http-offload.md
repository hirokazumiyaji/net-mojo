# HTTP handler offload

`WorkerPool` runs explicitly submitted HTTP jobs on reusable OS threads.
A handler detaches its response and transfers the resulting `ResponseSender`
and an owned `HandlerJob` to `pool.submit(sender, job)`.
The connection actor retains socket and reactor ownership.
`writer.offload(pool, job)` combines detach and submit. Failed detach destroys
the unsubmitted job; errors after detach follow sender ownership and abort
rules. No caller needs private detach rollback.

## Admission and ownership

`WorkerPoolConfig` defaults to half the online CPU count, with at least one
worker, a queue limit of 1024, and a shutdown grace of five seconds.
An explicit positive `workers` value fixes the number of threads.
Negative worker counts or queue limits are invalid.
A zero queue limit refuses every submission.

`submit` consumes both values on every outcome. It returns `True` when the
job enters the queue. A full or closed pool completes the detached response
with status 503 and `Retry-After: 1`, then returns `False`.
An inactive sender or allocation failure raises `OffloadError`, which names
the existing `NetError` contract.

The queue is FIFO. With multiple workers, job completion can occur in a
different order. The existing HTTP connection actor controls response order.
Jobs already cancelled before execution are discarded without calling `run`.
A thrown job error or an unfinished sender produces the existing abort outcome.

The queue limit bounds pending job count, separately from connection buffer
budgets. It does not bound the memory a user-defined job owns. Request values
must be copied or transferred into a job; jobs must not borrow handler-local
storage or retain raw pointers to Server state.

## Shutdown and lifetime

Call Server shutdown before pool shutdown. `shutdown` stops admission and
waits for accepted jobs until the configured monotonic grace deadline.
Workers that finish are joined. At grace expiry, pending and active response
capabilities are cancelled and unfinished workers are detached.
Queued jobs are skipped and destroyed by workers as they drain the queue.
The pool destructor applies the same policy, and repeated shutdown is harmless.

Shutdown returns at grace even if arbitrary user code or a job destructor
remains blocked. It does not stop that code. A blocked worker retains shared
pool state and its response capability until the job and its destruction
finish, so either the pool or Server may be destroyed first. Eventual cleanup
requires the external operation to return. Job code should observe
`sender.is_cancelled()` and stop its own work when practical.

Submission and shutdown share a mutex and may run concurrently while the
pool object remains alive. Destroying the pool concurrently with a caller
using a raw pointer to it is outside the API contract.

## Synchronization

One stable heap allocation holds the queue, worker records, a mutex, and a
condition variable. The pool owner and each started worker hold independent
references. References are released after unlocking the mutex; the last
reference destroys synchronization state. Job execution and destruction
always occur outside that mutex.

Cancellation takes the pool mutex before a response capability mutex. It
retains a separate response reference and never releases the connection
actor's ownership. Condition storage and timed waits support macOS and
64-bit Linux. No request creates a fresh thread, and no shutdown uses
`pthread_cancel`.

## Owned streaming input

Enable request streaming, claim `req.body_reader()`, and move its detached
`RequestBodyReceiver` into a job before calling `writer.offload(pool, job)`.
The job receives into bounded scratch with `receive(buffer, timeout)` and
obtains trailers after EOF. It never retains a borrowed Request or invokes
socket methods. The receiver's destruction discards remaining input, including
when a full pool refuses the job. Server shutdown cancels a blocked receiver;
the pool's separate grace policy still applies to arbitrary user code.

`examples/http_offload_body.mojo` reads an 8 KiB chunked upload using a 32-byte
input queue and 17-byte scratch buffer while a sibling connection completes.
The pool integration tests also cover refusal followed by a pipelined request
and cancellation after Server destruction.
