-- pex: solved ac73db5f
-- With all rings placed, the hand hid them, closed the relic (waiting for its animation), opened a
-- small portal, and 0.33 s later made four ghost skulls that circled (3.25 s), rose (2 s), flew to
-- the summon marker (0.5 s), vanished into a portal, and 0.33 s later set stage 75. Now a Solving
-- state steps those; the skulls are fields.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Closing", "Portal", "Circling", "Rising", "Flying", "Summoned")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)
	for i = 1, 4 do C.__vars["skull" .. i] = rt.form("ObjectReference") end
	local Solving = rt.state(C, "Solving")

	local function skulls(self) return { self.skull1, self.skull2, self.skull3, self.skull4 } end

	function C:solved()
		if self.step ~= S.Idle then return end
		self.myRing:Disable()
		self.otherRingA:Disable()
		self.otherRingB:Disable()
		self.otherRingC:Disable()
		self.relic:PlayAnimation("close")
		self.step = S.Closing
		self:GotoState("Solving")
	end

	function Solving:OnTick()
		if self.step == S.Closing then
			if self.relic:IsAnimRunning("close") then return end
			self.palmMarker:PlaceAtMe(self.summonTargetFXActivator):SetScale(0.2)
			self.step = S.Portal
			self.t = 0.33
		elseif self.t > 0 then
			return
		elseif self.step == S.Portal then
			for i = 1, 4 do self["skull" .. i] = self.palmMarker:PlaceAtMe(self.BoneHumanSkullStatic) end
			local s = skulls(self)
			for _, k in ipairs(s) do self.GhostFXShader:Play(k) end
			local a, off, speed = s[0], 56.0, 15.0
			a:TranslateTo(a.x - off, a.y, a.z, self:fr(), self:fr(), 180, speed)
			s[1]:TranslateTo(a.x, a.y + off, a.z, self:fr(), self:fr(), -90, speed)
			s[2]:TranslateTo(a.x + off, a.y, a.z, self:fr(), self:fr(), 360, speed)
			s[3]:TranslateTo(a.x, a.y - off, a.z, self:fr(), self:fr(), 90, speed)
			self.step = S.Circling
			self.t = self.t + 3.25
		elseif self.step == S.Circling then
			local s = skulls(self)
			local a = s[0]
			for i, k in ipairs(s) do k:TranslateTo(a.x, a.y, a.z + 96.0, self:fr(), self:fr(), ({ 0, 90, 180, -90 })[i], 25.0) end
			self.step = S.Rising
			self.t = self.t + 2.0
		elseif self.step == S.Rising then
			local m = self.summonMarker
			for _, k in ipairs(skulls(self)) do k:TranslateTo(m.x, m.y, m.z, 0, 0, 0, 750.0) end
			self.step = S.Flying
			self.t = self.t + 0.5
		elseif self.step == S.Flying then
			for _, k in ipairs(skulls(self)) do k:Disable() end
			self.summonMarker:PlaceAtMe(self.summonTargetFXActivator)
			self.step = S.Summoned
			self.t = self.t + 0.33
		elseif self.step == S.Summoned then
			self.step = S.Idle
			self:GotoState("")
			self.dunMidden01QST:SetStage(75)
		end
	end
end
