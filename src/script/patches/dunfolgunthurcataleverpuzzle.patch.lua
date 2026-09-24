-- pex: waitingforplayer.onactivate f65c66fd
-- A lever pull toggled its gates, played the lever's push or pull and waited for its end before
-- taking the next pull. Now WaitingForLever polls that lever's animation; `lever` and
-- `lever_anim` are the move under way.
local rt = require('skymod.rt')

return function(C)
	C.__vars.lever = rt.form("ObjectReference")
	C.__vars.lever_anim = rt.string("")
	C.__vars.TickRate = rt.float(0.1)
	local Player, Lever = rt.state(C, "WaitingForPlayer"), rt.state(C, "WaitingForLever")

	-- the gates each lever toggles
	local GATES = { { 1, 3, 4 }, { 2, 3 }, { 3 }, { 1, 4 } }

	function Player:OnActivate(triggerRef)
		self:GotoState("WaitingForLever")
		for n = 1, 4 do
			local lever = self["Lever" .. n]
			if triggerRef == lever then
				for _, g in ipairs(GATES[n - 1]) do self["Gate" .. g]:Activate(self) end
				local up = self["Lever" .. n .. "Up"]
				self["Lever" .. n .. "Up"] = not up
				self.lever, self.lever_anim = lever, up and "FullPull" or "FullPush"
				lever:PlayAnimation(self.lever_anim)
				return self:OnTick()
			end
		end
		-- not a lever: it stays in WaitingForLever, as in Papyrus
	end

	function Lever:OnTick()
		if self.lever_anim == "" or self.lever:IsAnimRunning(self.lever_anim) then return end
		self.lever_anim = ""
		self:GotoState("WaitingForPlayer")
	end
end
