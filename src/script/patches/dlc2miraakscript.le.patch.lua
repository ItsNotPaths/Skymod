-- pex: appear 737beb15
-- pex: disappear 4a95c0b2
-- pex: onload ebc83649
-- pex: onupdate 897a4a94
-- LE: Appear waits 2 s, Disappear 0.5 s, and OnUpdate spins a crossfade poll while Appeared.
-- Each wait is a timer and the poll is OnTick, all in the Active state, left when all three end.
-- OnLoad needs no change: it calls Appear, which now returns at once.
local rt = require('skymod.rt')

local CROSSFADE_DISTANCE = 1500

return function(C)
	local split_tick = C.__fn.ontick -- this class's S6 split waits; an OnTick here must run them
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.appearing = rt.bool(false)
	C.__vars.appearT = rt.timer(0.0)
	C.__vars.disappearing = rt.bool(false)
	C.__vars.disappearT = rt.timer(0.0)
	C.__vars.crossFading = rt.bool(false)
	C.__vars.crossFaded = rt.bool(false)
	local Active = rt.state(C, "Active")

	local function trace(self, s) rt.static("Debug", "Trace", tostring(self) .. s) end

	function C:Appear(MoveToAppearAtRef, UseIMOD)
		if self.appearing then return end
		trace(self, "Appear()")
		self.Appeared = true
		if MoveToAppearAtRef and self.AppearAtRef then
			self:MoveTo(self.AppearAtRef, 200)
		end
		if self:IsDisabled() then
			self:Enable(true)
		end
		self:setAlpha(0)
		self:PlaceAtMe(self.DLC2MiraakTeleportExp)
		if UseIMOD then
			self:RegisterForSingleUpdate(0.001)
		end
		trace(self, "Waiting...")
		self.appearing = true
		self.appearT = 2.0
		self:GotoState("Active")
	end

	function C:Disappear()
		if self.disappearing then return end
		self.Appeared = false
		self:PlaceAtMe(self.DLC2MiraakTeleportReturnExp)
		self.DLC2MiraakTeleportReturnFXS:Play(self)
		self.disappearing = true
		self.disappearT = 0.5
		self:GotoState("Active")
	end

	function C:OnUpdate()
		if self.crossFading then return end
		self.crossFading = true
		self.crossFaded = false
		self:GotoState("Active")
		self:OnTick()
	end

	local function crossfade_poll(self)
		if not self.Appeared then
			self.crossFading = false
			return
		end
		local near = self:GetDistance(rt.static("Game", "GetPlayer")) <= CROSSFADE_DISTANCE
		if near and not self.crossFaded then
			self.crossFaded = true
			self.DLC2MiraakTeleportIMODStatic:ApplyCrossFade(3)
		elseif not near and self.crossFaded then
			self.crossFaded = false
			rt.static("ImageSpaceModifier", "RemoveCrossFade", 3)
		end
	end

	function Active:OnTick()
		if split_tick then split_tick(self) end
		if self.appearing and self.appearT <= 0 then
			self.appearing = false
			self:setAlpha(1, true)
			self.DLC2MiraakTeleportStartFXS:Play(self)
			trace(self, "setAlpha(1, true)")
		end
		if self.disappearing and self.disappearT <= 0 then
			self.disappearing = false
			rt.static("ImageSpaceModifier", "RemoveCrossFade", 3)
			self:setAlpha(0, true)
			self:Disable(true)
			if self.DisappearToRef then
				self:MoveTo(self.DisappearToRef)
			end
		end
		if self.crossFading then crossfade_poll(self) end
		if not (self.appearing or self.disappearing or self.crossFading) then
			self:GotoState("")
		end
	end
end
