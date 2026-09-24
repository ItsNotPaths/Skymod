-- pex: fragment_13 78a3cad0
-- pex: fragment_16 ec99a002
-- pex: fragment_20 14c20e22
-- pex: fragment_22 6258e528
-- pex: fragment_23 4b1bad64
-- pex: fragment_25 2b7237d6
-- pex: fragment_26 e205a704
-- pex: fragment_32 c2e4bc5f
-- Eight fragments set up the Bard's next scene: stop all ten BardGhost scenes, wait 1 s, then
-- move him to the next position and start that scene. Fragment_16 alone can skip straight to
-- stage 39 instead. They share one clock: a second fragment while one is settling is dropped
-- (the safety stop still runs), which matches how the quest advances them one stage at a time.
local rt = require('skymod.rt')

local function trace(msg) rt.static("Debug", "Trace", "DeadMensRespite: " .. msg) end

return function(C)
	C.BardScene = rt.sequence("Idle", "S02", "S03", "S04", "S05", "S06", "S07", "S08", "S09")
	C.__vars.bardScene = C.BardScene.Idle
	C.__vars.bardWait = rt.timer(0.0)
	local S = C.BardScene

	local function stop_ghosts(self)
		for i = 1, 10 do self[string.format("BardGhost%02d", i)]:Stop() end
	end

	local function move_and_start(self, n)
		local pos = self[string.format("Alias_BardScene%02dPosition", n)]
		self.Alias_Bard:GetReference():Moveto(pos:GetReference(), 0.0, 0.0, 0.0, true)
		self.Alias_Bard:GetReference():Enable(false)
		rt.cast(self.Alias_Bard:GetActorRef(), "dundeadmensbardghostscript"):PopIn()
		self[string.format("BardGhost%02d", n)]:Start()
		self.Alias_Bard:GetActorRef():EvaluatePackage()
	end

	local FINISH = {
		[S.S02] = function(self)
			if self:GetStageDone(30) then self:SetStage(39) return end
			move_and_start(self, 2)
		end,
		[S.S03] = function(self) move_and_start(self, 3) end,
		[S.S04] = function(self) move_and_start(self, 4) end,
		[S.S05] = function(self) move_and_start(self, 5) end,
		[S.S06] = function(self) move_and_start(self, 6) end,
		[S.S07] = function(self) move_and_start(self, 7) end,
		[S.S08] = function(self) move_and_start(self, 8) end,
		[S.S09] = function(self)
			move_and_start(self, 9)
			self.Alias_Bard:GetActorRef():SetGhost(false)
		end,
	}

	local function start(self, stage)
		stop_ghosts(self)
		if self.bardScene ~= S.Idle then
			trace("dropped, already settling to " .. self.bardScene.name)
			return
		end
		self.bardScene = stage
		self.bardWait = 1.0
	end

	function C:Fragment_13() start(self, S.S08) end
	function C:Fragment_16() start(self, S.S02) end
	function C:Fragment_20() start(self, S.S03) end
	function C:Fragment_22() start(self, S.S04) end
	function C:Fragment_23() start(self, S.S05) end
	function C:Fragment_25() start(self, S.S06) end
	function C:Fragment_26() start(self, S.S07) end
	function C:Fragment_32() start(self, S.S09) end

	local split_tick = C.__fn.ontick -- fragments 28, 34, 35 already tick; keep them running
	function C:OnTick()
		split_tick(self)
		if self.bardScene == S.Idle or self.bardWait > 0 then return end
		local stage = self.bardScene
		self.bardScene = S.Idle -- before the action it guards
		trace("settled to " .. stage.name)
		FINISH[stage](self)
	end
end
