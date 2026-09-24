-- pex: catchup a5618732
-- pex: fadein c96741d5
-- pex: fadeout bdec6d1b
-- pex: onenterbleedout a39d28ab
-- Katria's fades waited: FadeIn 0.01 s then 2 s, FadeOut 2.5 s; CatchUp faded out, moved, faded in;
-- bleedout faded out, waited 5 s, then came back. Each is now a run stepped by OnTick in "Busy".
-- Callers wait while `fade` is not Idle; Warp is the fade-out, move, fade-in that callers repeated.
local rt = require('skymod.rt')

return function(C)
	C.Fade = rt.sequence("Idle", "Out", "Enabling", "In")
	C.Bleed = rt.sequence("Idle", "Fading", "Down", "Returning")
	local F, B = C.Fade, C.Bleed
	local v = C.__vars
	v.fade, v.fade_t = F.Idle, rt.timer(0.0)
	v.shown = rt.bool(true)                        -- the visibility the last FadeIn/FadeOut asked for
	v.warp_to = rt.form("ObjectReference")          -- where Katria belongs, not moved there yet
	v.bleed, v.bleed_t = B.Idle, rt.timer(0.0)
	local Busy = rt.state(C, "Busy")

	local function busy(self)
		if self:GetState() ~= "Busy" then self:GotoState("Busy") end
	end

	-- `late` is the overshoot of the step that chains into this one (0 for a fresh start)
	local function fade_in(self, late)
		self.fade = F.Enabling
		self.fade_t = late + 0.01
		busy(self)
		self:Enable(false)
	end

	local function fade_out(self, late)
		self.fade = F.Out
		self.fade_t = late + 2.5
		busy(self)
		self:SetAlpha(0.0, true)
	end

	-- a request during a run is settled when that run ends
	function C:FadeIn()
		self.shown = true
		if self.fade == F.Idle then fade_in(self, 0.0) end
	end

	function C:FadeOut()
		self.shown = false
		if self.fade == F.Idle then fade_out(self, 0.0) end
	end

	function C:Warp(moveTarget)
		self.warp_to = moveTarget
		self.shown = true
		if self.fade == F.Idle then fade_out(self, 0.0) end
	end

	function C:CatchUp(moveTarget)
		if self.isCatchingUp then return end
		if self:GetDistance(moveTarget) > 2000 and self:GetDistance(rt.static("Game", "GetPlayer")) > 2000 then
			self.isCatchingUp = true
			self:Warp(moveTarget)
		end
	end

	function C:OnEnterBleedout()
		if self.bleed ~= B.Idle then return end
		self.bleed = B.Fading
		busy(self)
		self:SetNoBleedoutRecovery(true)
		self:FadeOut()
	end

	local function fade_tick(self)
		if self.fade == F.Idle or self.fade_t > 0 then return end
		if self.fade == F.Enabling then
			self.fade = F.In
			self.fade_t = self.fade_t + 2.0
			self:SetAlpha(0.0, false)
			return
		end
		if self.fade == F.In then
			self.fade = F.Idle
			self:SetAlpha(0.25, true)
			if self.warp_to or not self.shown then fade_out(self, self.fade_t) end
		elseif self.fade == F.Out then
			self.fade = F.Idle
			self:Disable()
			if self.warp_to then
				local to = self.warp_to
				self.warp_to = rt.None
				self:MoveTo(to)
			end
			if self.shown then fade_in(self, self.fade_t) end
		end
		if self.fade == F.Idle then self.isCatchingUp = false end
	end

	local function bleed_tick(self)
		if self.bleed == B.Idle then return end
		if self.bleed == B.Fading then
			if self.fade ~= F.Idle then return end
			self:SetNoBleedoutRecovery(false)
			self.bleed = B.Down
			self.bleed_t = 5.0
		elseif self.bleed == B.Down then
			if self.bleed_t > 0 then return end
			self.bleed = self.KatriaTeleportingOut and B.Idle or B.Returning
			self:MoveToPackageLocation()
			self:RestoreAV("Health", self:GetAV("Health") / 2)
			if self.bleed == B.Returning then self:FadeIn() end
		elseif self.fade == F.Idle then
			self.bleed = B.Idle
			if self.lastAttacker == rt.static("Game", "GetPlayer") and not self.hasPlayedAllyDeathScene then
				self.hasPlayedAllyDeathScene = true
				self.DLC1LD_KatriaKilledByPlayer:Start()
			end
		end
	end

	-- fade first, so the bleedout sees a fade that ended this tick
	function Busy:OnTick()
		fade_tick(self)
		bleed_tick(self)
		if self.fade == F.Idle and self.bleed == B.Idle then self:GotoState("") end
	end
end
