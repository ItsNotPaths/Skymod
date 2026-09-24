-- pex: enemyseconddied 549f97ca
-- Polled IsBleedingOut every 1s, then did the stage-200 cleanup, then waited PauseBeforeScene
-- before starting scene B. Now a stage of rt.sequence plus a timer, read from OnTick (1 Hz, same
-- cadence as the original poll). The class already ticks (S6 split); call it first.
local rt = require('skymod.rt')

return function(C)
	C.Stage = rt.sequence("Idle", "WaitBleedout", "WaitScene")
	C.__vars.stage = C.Stage.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(1.0)

	function C:EnemySecondDied()
		if self.stage ~= C.Stage.Idle then return end -- a second start is dropped
		self.stage = C.Stage.WaitBleedout
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if self.stage == C.Stage.WaitBleedout then
			local enemyLeaderActor = self.EnemyLeader:GetActorReference()
			if not enemyLeaderActor:IsBleedingOut() then return end
			self:setStage(200)
			local playerActor = rt.static("Game", "GetPlayer")
			self.EnemyLeader:TryToRemoveFromFaction(self.CrimeFactionHaafingar)
			self.EnemyLeader:TryToRemoveFromFaction(self.CrimeFactionEastmarch)
			enemyLeaderActor:RemoveFromFaction(self.CWImperialFactionNPC)
			enemyLeaderActor:RemoveFromFaction(self.CWSonsFactionNPC)
			self:makeMeStopCombat(self.Leader)
			self:makeMeStopCombat(self.Second)
			self:makeMeStopCombat(self.EnemyLeader)
			playerActor:StopCombat()
			playerActor:StopCombatAlarm()
			self.CWFinaleSolitudeSceneA:stop()
			self.stage = C.Stage.WaitScene
			self.t = self.t + self.pausebeforescene
			return
		end
		if self.stage == C.Stage.WaitScene then
			if self.t > 0 then return end
			self.stage = C.Stage.Idle
			self:startSceneB()
		end
	end
end
