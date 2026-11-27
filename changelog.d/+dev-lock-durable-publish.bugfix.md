A failed sync or close while writing `eb-local.lock` leaves the previous lock in place. A new lock is published only after its bytes are durable, and a failed write removes its temporary file.
