-- pex: solution.onactivate d96262c5
-- pex: start.onactivate ae7021da
-- Start waited 3 s before lighting the first line. The solution played Line06 and "open" on the
-- puzzle base, each waited for. Now a timer and OnTick polls on the base's animations do it.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Starting", "Line06", "Opening")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Start, Solution, Done = rt.state(C, "Start"), rt.state(C, "Solution"), rt.state(C, "done")

	function Start:OnActivate(triggerRef)
		if rt.static("Game", "GetPlayer"):IsInCombat() then return end
		self:GotoState("Solution")
		self.step = S.Starting
		self.t = 3.0
	end

	function Solution:OnTick()
		if self.step ~= S.Starting or self.t > 0 then return end
		self.step = S.Idle
		self.puzzleBase:Activate(self.puzzleBase)
		self.puzzleBase:PlayAnimation("Line01")
		self.QSTSeranaTombMagicAmbience2D:Play(self.puzzleBase)
	end

	-- each lit line locks the brazier before it; a brazier moved away unlocks it again
	function Solution:OnActivate(triggerRef)
		local base = self.puzzleBase
		local function b(n) return self["Brazier0" .. n .. "Script"] end
		local function s(n) return b(n).solved end
		if self.LightPoint == 1 and s(1) then
			self.LightPoint = 2
			base:PlayAnimation("Line02")
		elseif self.LightPoint == 2 and not s(1) then
			self.LightPoint = 1
			base:PlayAnimation("Line01")
		end
		for n = 2, 4 do -- lines 3..5: braziers 1..n solved lights line n+1
			local lower = true
			for k = 1, n - 1 do lower = lower and s(k) end
			if self.LightPoint == n and lower and s(n) then
				base:PlayAnimation("Line0" .. (n + 1))
				self.LightPoint = n + 1
				b(n - 1).Locked = true
			elseif self.LightPoint == n + 1 and lower and not s(n) then
				self.LightPoint = n
				base:PlayAnimation("Line0" .. n)
				b(n - 1).Locked = false
			end
		end
		if self.LightPoint ~= 5 then return end
		for n = 1, 5 do if not s(n) then return end end
		self:GotoState("done")
		b(4).Locked = true
		base:PlayAnimation("Line06")
		self.step = S.Line06
	end

	function Done:OnTick()
		if self.step == S.Line06 and not self.puzzleBase:IsAnimRunning("Line06") then
			for n = 1, 5 do self["Brazier0" .. n .. "Script"]:GotoState("done") end
			self.puzzleBase:RampRumble(1, 4, 1500)
			self.puzzleBase:PlayAnimation("open")
			self.step = S.Opening
		elseif self.step == S.Opening and not self.puzzleBase:IsAnimRunning("open") then
			self.step = S.Idle
			self.coffinActivator:Enable()
			self.gate:SetOpen(false)
			self:Disable()
		end
	end
end
