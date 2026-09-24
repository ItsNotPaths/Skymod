-- The 120 s window that dunBluePalaceWabbajackSCRIPT.nightMareHandler waited through when Pelagius
-- raised the first nightmare, then the undo of the dreams one second apart (unless all five were
-- fixed). It runs here because the dreams are this controller's. OnTick in Reverting.
local rt = require('skymod.rt')

return function(C)
	C.__vars.revert_undone = rt.int(0) -- dreams undone so far; 0 while the window runs
	C.__vars.revert_sw = rt.stopwatch(0.0)
	C.__vars.revert_fx = rt.form("Explosion")
	C.__vars.TickRate = rt.float(0.1)
	local Reverting = rt.state(C, "Reverting")

	function C:StartRevert(explosion)
		if self:GetState() == "Reverting" then return end -- Papyrus ran a second window in parallel
		self.revert_fx = explosion
		self.revert_undone = 0
		self.revert_sw = 0.0
		self:GotoState("Reverting")
	end

	function Reverting:OnTick()
		local wait = self.revert_undone == 0 and 120.0 or 1.0
		if self.revert_sw < wait then return end
		if self.revert_undone == 0 and self.dreamFixed == 5 then return self:GotoState("") end
		self.revert_sw = self.revert_sw - wait
		local i = self.revert_undone + 1
		self.revert_undone = i
		self["dream" .. i]:PlaceAtMe(self.revert_fx)
		self["nightmare" .. i]:Disable()
		self["dream" .. i]:Disable()
		if i == 5 then
			self.dreamFixed = 0
			self:GotoState("")
		end
	end
end
