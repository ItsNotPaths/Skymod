-- pex: ondeath 7438029d
-- OnDeath waited only through CrabDied, which no longer waits (its lock loop is dead code); unchanged.
return function(C) end
