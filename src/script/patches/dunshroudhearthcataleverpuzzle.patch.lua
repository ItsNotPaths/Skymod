-- pex: waitingforplayer.onactivate a2503377
-- A lever pull toggled its gates, then played the lever's animation and waited for it in
-- WaitingForLever. Now OnTick in that state polls the lever's animation.
local rt = require('skymod.rt')

return function(C)
	C.__vars.lever = rt.form("ObjectReference")
	C.__vars.anim = rt.string("")
	C.__vars.TickRate = rt.float(0.1)
	local ForPlayer, ForLever = rt.state(C, "WaitingForPlayer"), rt.state(C, "WaitingForLever")

	local GATES = { { 1, 3 }, { 1, 2, 3 }, { 1, 2 } }

	function ForPlayer:OnActivate(triggerRef)
		self:GotoState("WaitingForLever")
		self.dunShroudHearthQST:SetStage(15)
		for i = 1, 3 do
			local lever = self["Lever" .. i]
			if triggerRef == lever then
				for _, g in ipairs(GATES[i - 1]) do self["Gate" .. g]:Activate(self) end
				local up = self["Lever" .. i .. "Up"]
				self["Lever" .. i .. "Up"] = not up
				self.lever, self.anim = lever, up and "FullPull" or "FullPush"
				lever:PlayAnimation(self.anim)
				return
			end
		end
	end

	function ForLever:OnTick()
		if self.anim == "" or self.lever:IsAnimRunning(self.anim) then return end
		self.anim = ""
		self:GotoState("WaitingForPlayer")
	end
end
