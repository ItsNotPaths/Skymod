-- pex: ondeath 9ab8bc4c
-- OnDeath waited only through GuardDied, which no longer waits (its lock loop is dead code); unchanged.
return function(C) end
