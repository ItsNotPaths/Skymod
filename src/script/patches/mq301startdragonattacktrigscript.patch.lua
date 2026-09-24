-- pex: waiting.ontriggerenter e17c281e
-- AdvanceDragonAttackScene returns its result at once now (stage 2 is the only one that waited);
-- the trigger then leaves "waiting" at once, which also keeps a second enter from repeating stage 2.
return function(C) end
