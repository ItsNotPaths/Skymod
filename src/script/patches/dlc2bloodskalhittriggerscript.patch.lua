-- pex: waiting.ontriggerenter c8b2e2c6
-- No change: OnTriggerEnter calls SendHitToController (free, tail) then disables itself.
-- SendHitToController's callee, ProcessHitEvent, is now start-and-return, so this handler already
-- runs to completion on the same tick as before; nothing here depends on the callee finishing.
return function(C)
end
