-- pex: fireselfandlinkedrefs ba4b3bc0
-- pex: startfiring 91428aed
-- StartFiring's countDown is computed once, then reused every cycle (not re-randomized; matches
-- the original, which never recomputes it inside its while loop). FireSelfAndLinkedRefs's per-child
-- wait becomes a fact-driven pass over the linked-ref chain: fireIdx is a loop index over data
-- (script-api.md section 2), fireT the per-child delay, fireSetup a one-shot guard so the angle
-- setup and translate run once per child, not every tick.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.05)
	C.Step = rt.sequence("Cycling", "Volleying")
	C.__vars.step = C.Step.Cycling
	C.__vars.cycleCountDown = rt.float(0.0)
	C.__vars.cycleT = rt.timer(0.0)
	C.__vars.fireIdx = rt.int(0)
	C.__vars.fireT = rt.timer(0.0)
	C.__vars.fireSetup = rt.bool(false)
	C.__vars.fireValid = rt.bool(false)
	local Active = rt.state(C, "Firing")

	local function phase_matches(self)
		local p = self.CWBattlePhase:GetValue()
		if p == 1 then return self.FireInPhase1
		elseif p == 2 then return self.FireInPhase2
		elseif p == 3 then return self.FireInPhase3
		elseif p == 4 then return self.FireInPhase4
		elseif p == 5 then return self.FireInPhase5
		end
		return false
	end

	function C:StartFiring()
		if self.firing then return end -- a run happens once
		self.firing = true
		self.cycleCountDown = rt.static("Utility", "RandomFloat", self.WaitTimeMin, self.WaitTimeMax)
		self.cycleT = self.cycleCountDown
		self.step = C.Step.Cycling
		self:GotoState("Firing")
	end

	local function start_volley(self)
		self.fireIdx = 0
		self.fireSetup = false
		self.fireT = 0.0
		self.step = C.Step.Volleying
	end

	local function setup_child(self, child)
		self.fireSetup = true
		if child:GetParentCell() == rt.None or not child:Is3DLoaded() then
			self.fireValid = false
			self.fireT = 0.0
			return
		end
		self.fireValid = true
		local ax, ay, az = child:GetAngleX(), child:GetAngleY(), child:GetAngleZ()
		if self.AimDevianceVertical ~= 0 then
			local dev = rt.static("Utility", "RandomFloat", -self.AimDevianceVertical, self.AimDevianceVertical)
			ax = self.initialAngleX + dev
		end
		if self.AimDevianceHorizontal ~= 0 then
			local dev = rt.static("Utility", "RandomFloat", -self.AimDevianceHorizontal, self.AimDevianceHorizontal)
			az = self.initialAngleZ + dev
		end
		child:TranslateTo(child.X, child.Y, child.Z, ax, ay, az, 9999999)
		if self.TimeToFireDeviance ~= 0 then
			self.fireT = rt.static("Utility", "RandomFloat", 0, self.TimeToFireDeviance)
		else
			self.fireT = 0.0
		end
	end

	function Active:OnTick()
		if not self.firing then self:GotoState("") return end
		if self.step == C.Step.Cycling then
			if self.cycleT > 0 then return end
			if not phase_matches(self) then return end -- spin guard: Papyrus looped with no wait here
			start_volley(self)
			return
		end
		local countRefs = self:countLinkedRefChain(rt.None, 100) - 1
		if self.fireIdx > countRefs then
			self.step = C.Step.Cycling
			self.cycleT = self.cycleCountDown
			return
		end
		local child = self:GetNthLinkedRef(self.fireIdx)
		if not self.fireSetup then setup_child(self, child) end
		if self.fireT > 0 then return end
		if self.fireValid then
			self.WeaponToFire:fire(child, self.AmmoToFire)
		end
		self.fireIdx = self.fireIdx + 1
		self.fireSetup = false
	end
end
