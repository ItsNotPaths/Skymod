-- pex: fragment_3 4433eeaf
-- Fragment_3 called ObserverDoTransform (blocking) then cleared the observer's own LookAt.
-- ObserverDoTransform is now start-and-return; the reachable LookAt writes in its callee chain
-- (FightStart clears the FIVE FIGHTERS' LookAt, never the observer's) do not touch what this
-- ClearLookAt writes, so running it right after the call, instead of after, changes nothing.
local rt = require('skymod.rt')

return function(C)
	function C:Fragment_3()
		local quest = rt.cast(self:GetOwningQuest(), "c01questscript")
		quest:ObserverDoTransform()
		self.Observer:GetActorRef():ClearLookAt()
	end
end
