-- pex: onload 7ff43ecf
-- OnLoad looped while `on`: roll an effect and a 10-30 s wait, wait, play the effect. Effect 1
-- is three steps 0.5 s and 3 s apart. The loop is now OnTick in the running state.
-- HOLE(vfx, gap): a cosmetic loop run as a saved script. It belongs in the effect itself, with no script state and nothing saved.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.5) -- divides the fixed waits; the random one needs no precision
	C.Step = rt.sequence("Waiting", "Dropping", "Settling")
	C.__vars.step = C.Step.Waiting
	C.__vars.waitT = rt.timer(0.0)
	local Running = rt.state(C, "Running")

	-- The top of the Papyrus loop: `on` is read only here, so an unload mid-cycle finishes it.
	local function next_cycle(self)
		self.step = C.Step.Waiting
		if not self.on then return self:GotoState("") end
		self.chooser = rt.static("Utility", "RandomInt", 1, 3)
		self.waitT = self.waitT + rt.static("Utility", "RandomFloat", 10.0, 30.0)
	end

	function C:OnLoad()
		self.on = true
		if self:GetState() == "Running" then return end -- a run happens once
		self.waitT = 0.0
		self:GotoState("Running")
		next_cycle(self)
	end

	function Running:OnTick()
		if self.waitT > 0 then return end
		if self.step == C.Step.Waiting then
			if self.chooser == 1 then
				self:PlayAnimation("PlayAnim01")
				self.mySFX:Play(self)
				self.step = C.Step.Dropping
				self.waitT = self.waitT + 0.5
				return
			end
			self:PlayAnimation(self.chooser == 2 and "PlayAnim02" or "PlayAnim03")
			self.mySFX:Play(self)
		elseif self.step == C.Step.Dropping then
			self:PlaceAtMe(self.FallingDustExplosion01)
			self.step = C.Step.Settling
			self.waitT = self.waitT + 3.0
			return
		else
			self:PlayAnimation("PlayAnim02")
		end
		next_cycle(self)
	end
end
