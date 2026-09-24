-- pex: normal.ondeath 385428f9
-- OnDeath(normal) went busy, called TryToRespawn (which waited, then respawned) and only then came
-- back to normal. TryToRespawn now starts the wait on this alias and returns; this stays "respawning"
-- (so a second OnDeath is dropped by the state's own no-op override) until OnTick sees the wait end.
local rt = require('skymod.rt')

return function(C)
	C.__vars.respawn_t = rt.timer(rt.None)
	C.__vars.respawn_quest = rt.form("defaultquestrespawnscript")
	local Normal = rt.state(C, "normal")

	function Normal:OnDeath(akKiller)
		if not self.brespawningon then return end
		local myQuest = rt.cast(self:GetOwningQuest(), "defaultquestrespawnscript")
		self:GotoState("respawning")
		myQuest:TryToRespawn(self)
		if self.respawn_t == rt.None then
			self:GotoState("normal")
		end
	end

	function C:OnTick()
		if self.respawn_t == rt.None or self.respawn_t > 0 then return end
		self.respawn_t = rt.None
		local myQuest = self.respawn_quest
		self.respawn_quest = nil
		if self.brespawningon then
			myQuest:Respawn(self)
		end
		self:GotoState("normal")
	end
end
