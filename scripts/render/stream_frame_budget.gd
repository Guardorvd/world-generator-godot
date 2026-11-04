extends RefCounted
## Shared main-thread deadline. A native upload is indivisible and may overrun it once.
var deadline_usec := 0

func allows_work() -> bool:
	return deadline_usec == 0 or Time.get_ticks_usec() < deadline_usec

func deadline(local_us: int) -> int:
	var until := Time.get_ticks_usec() + local_us
	return mini(until, deadline_usec) if deadline_usec > 0 else until
