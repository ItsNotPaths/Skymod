-- pex: endmikrulbattle 1341ad20
-- pex: beginmikrulbattle 423ece83
-- BeginMikrulBattle's two Waits become a stage plus one timer. EndMikrulBattle's own two beats
-- (kill the enemies, then wait for SummonFX) become a second stage; it starts
-- ActivateAndKillAllEnemies (dunprogressivecombatscriptrefalias.patch.lua) and polls `killing`
-- instead of calling it inline, since that call now returns at once. This class inherits its
-- OnTick from dunFolgunthurBossBattle (the S6 split's timer, RunUpdate's cadence, the two bursts);
-- call it first, then drain both of this class's own stages.
local rt = require('skymod.rt')

return function(C)
	C.BeginStage = rt.sequence("Idle", "Ghost", "Summon")
	C.__vars.beginStage = C.BeginStage.Idle
	C.__vars.beginT = rt.timer(0.0)
	local Begin = C.BeginStage

	local beginSteps = {}
	beginSteps[Begin.Ghost] = function(self)
		local actor = self:GetActorRef()
		actor:Disable(false)
		actor:MoveTo(self.mikrulstartpoint)
		actor:PlaceAtMe(self.summonfx)
		self.beginT = self.beginT + 1.0
		return Begin.Summon
	end
	beginSteps[Begin.Summon] = function(self)
		local actor = self:GetActorRef()
		actor:SetAV("Variable06", 0.0)
		actor:Enable(true)
		actor:Activate(rt.static("Game", "GetPlayer"))
		actor:SetGhost(false)
		rt.parent(self, "dunReachwaterRockMikrulBossBattle", "OnLoad")
		self.isactive = true
		self:RegisterForSingleUpdate(1.0)
		return Begin.Idle
	end

	function C:BeginMikrulBattle()
		if self.beginStage ~= Begin.Idle then return end -- a second start during a run is dropped
		local actor = self:GetActorRef()
		actor:SetAV("Variable06", 1.0)
		actor:EvaluatePackage()
		actor:SetGhost(true)
		actor:PlaceAtMe(self.banishfx)
		self.beginStage = Begin.Ghost
		self.beginT = 0.5
	end

	C.EndStage = rt.sequence("Idle", "Killing", "Finish")
	C.__vars.endStage = C.EndStage.Idle
	C.__vars.endT = rt.timer(0.0)
	local End = C.EndStage

	local endSteps = {}
	endSteps[End.Killing] = function(self)
		if self.killing then
			self.endT = 0.0 -- still activating/killing the enemies; hold, don't drift
			return nil
		end
		self.ally1alias:GetActorRef():Kill()
		self.ally2alias:GetActorRef():Kill()
		self.ally3alias:GetActorRef():Kill()
		self:GetActorRef():PlaceAtMe(self.summonfx)
		self.endT = self.endT + 1.0
		return End.Finish
	end
	endSteps[End.Finish] = function(self)
		local actor = self:GetActorRef()
		actor:Enable(true)
		actor:SetAlpha(0.33, false)
		actor:GetActorBase():SetEssential(true)
		actor:SetNoBleedoutRecovery(true)
		actor:DamageAV("Health", 10000.0)
		self.dungauldursonqst:SetStage(119)
		return "done"
	end

	function C:EndMikrulBattle()
		if self.endStage ~= End.Idle then return end -- a second start during a run is dropped
		self.isactive = false
		local actor = self:GetActorRef()
		actor:SetGhost(true)
		actor:PlaceAtMe(self.banishfx)
		actor:Disable(false)
		actor:Resurrect()
		actor:SetAV("Health", 10.0)
		actor:MoveTo(actor:GetLinkedRef(self.linkcustom02))
		self.breakloop = true
		self:ActivateAndKillAllEnemies()
		self.endStage = End.Killing
		self.endT = 0.0
	end

	function C:OnTick()
		rt.parent(self, "dunReachwaterRockMikrulBossBattle", "OnTick")
		while self.beginStage ~= Begin.Idle and self.beginT <= 0 do
			self.beginStage = beginSteps[self.beginStage](self)
		end
		while self.endStage ~= End.Idle and self.endT <= 0 do
			local nxt = endSteps[self.endStage](self)
			if not nxt then break end
			self.endStage = nxt == "done" and End.Idle or nxt
		end
	end
end
