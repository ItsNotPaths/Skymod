-- pex: onanimationevent e54d074d
-- BeginCastLeft armed the dragon arms and, 1 s later, spawned the dragons. Now a timer holds the
-- second. As in Papyrus, a RitualSpellOut in that second does not stop the spawn.
-- HOLE(magic, gap): runs on an effect instance, which nothing makes yet.
local rt = require('skymod.rt')

return function(C)
	C.__vars.spawn_t = rt.timer(rt.None)
	local split_tick = C.__fn.ontick

	local function disarm(self)
		local player = rt.static("Game", "GetPlayer")
		player:UnequipItem(self.dragonArms, true, true)
		self.dragonArmsFX:Stop(player)
		self.DRAGONSUMMON = false
		self:deSpawnDragons()
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if asEventName == "RitualSpellOut" or asEventName == "EnableBumper" then
			disarm(self)
		elseif asEventName == "BeginCastLeft" then
			local player = rt.static("Game", "GetPlayer")
			player:EquipItem(self.dragonArms, false, true)
			self.dragonArmsFX:Play(player)
			self.DRAGONSUMMON = true
			self.spawn_t = 1.0
		end
	end

	function C:OnTick()
		split_tick(self)
		if self.spawn_t == rt.None or self.spawn_t > 0 then return end
		self.spawn_t = rt.None
		if self.bSPAWNDRAGONS then self:spawnDragons() end
	end
end
