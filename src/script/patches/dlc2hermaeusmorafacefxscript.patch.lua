-- pex: hermaeusmoraappear.onbeginstate e4ef59fd
-- pex: hermaeusmoradisappear.onbeginstate 41237d95
-- pex: waitfor3d 980ffa40 c8c45ab1
-- Each state stepped through 8 face refs in order; odd faces disabled, waited, re-enabled and
-- polled Is3DLoaded (capped at iMaxCount) before setting the blend. Now OnTick in each state walks
-- the same 8 faces on a stage index plus a timer. WaitFor3D itself had no side effect besides the
-- wait (no field it sets is read), so a direct call to it is a no-op; the real delay is inlined below.
local rt = require('skymod.rt')

return function(C)
	C.Phase = rt.sequence("Idle", "Disabling", "Polling")
	C.__vars.hmFace = rt.int(0) -- 1..8 face being processed this run, 0 = idle
	C.__vars.hmPhase = C.Phase.Idle
	C.__vars.hmT = rt.timer(0.0)
	C.__vars.hmCount = rt.int(0)
	local Appear = rt.state(C, "HermaeusMoraAppear")
	local Disappear = rt.state(C, "HermaeusMoraDisappear")
	local P = C.Phase

	local function face_of(self, idx) return self["myHMface" .. ("%02d"):format(idx)] end

	function C:WaitFor3D(myFace) end

	function Appear:OnTick()
		while self.hmFace >= 1 and self.hmFace <= 8 do
			local idx = self.hmFace
			local face = face_of(self, idx)
			if self.hmPhase == P.Idle then
				if not face then
					self.hmFace = idx + 1
				elseif idx % 2 == 0 then
					face:SetAnimationVariableFloat("fToggleBlend", 1.0)
					self.hmFace = idx + 1
				else
					face:Disable()
					self.hmPhase = P.Disabling
					self.hmT = self.hmT + rt.static("Utility", "RandomFloat", 0.2, 0.5)
					return
				end
			elseif self.hmPhase == P.Disabling then
				if self.hmT > 0 then return end
				face:Enable()
				self.hmPhase = P.Polling
				self.hmCount = 0
				self.hmT = self.hmT + rt.static("Utility", "RandomFloat", 0.2, 0.5)
				return
			else -- Polling
				if self.hmT > 0 then return end
				if face:Is3DLoaded() or self.hmCount >= self.iMaxCount then
					face:SetAnimationVariableFloat("fToggleBlend", 1.0)
					self.hmPhase = P.Idle
					self.hmFace = idx + 1
				else
					self.hmCount = self.hmCount + 1
					self.hmT = self.hmT + rt.static("Utility", "RandomFloat", 0.2, 0.5)
					return
				end
			end
		end
		self.hmFace = 0
	end

	function Appear:OnBeginState()
		self.hmFace = 1
		self.hmPhase = P.Idle
		self.hmT = 0.0 -- starting a wait sets its clock; hmT free-runs while idle between runs
		self:OnTick()
	end

	function Disappear:OnTick()
		while self.hmFace >= 1 and self.hmFace <= 8 do
			local idx = self.hmFace
			local face = face_of(self, idx)
			if not face then
				self.hmFace = idx + 1
			elseif idx % 2 == 0 then
				face:SetAnimationVariableFloat("fToggleBlend", 0.0)
				self.hmFace = idx + 1
			elseif self.hmPhase == P.Idle then
				self.hmPhase = P.Disabling -- reused only as "waiting" here
				self.hmT = self.hmT + rt.static("Utility", "RandomFloat", 0.2, 0.5)
				return
			else
				if self.hmT > 0 then return end
				face:SetAnimationVariableFloat("fToggleBlend", 0.0)
				self.hmPhase = P.Idle
				self.hmFace = idx + 1
			end
		end
		self.hmFace = 0
	end

	function Disappear:OnBeginState()
		self.hmFace = 1
		self.hmPhase = P.Idle
		self.hmT = 0.0
		self:OnTick()
	end
end
