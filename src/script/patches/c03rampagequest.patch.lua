-- pex: turnback 5e704e4a
-- TurnBack polled bIsSynced every 0.1s, then ran one-shot steps split by a flat Wait(FadeSeconds).
-- __turningBack still guards the one-shot entry; a WaitSync/Fading stage plus one timer replaces
-- the poll and the flat wait.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.TurnStage = rt.sequence("Idle", "WaitSync", "Fading")
	C.__vars.turnStage = C.TurnStage.Idle
	C.__vars.turnT = rt.timer(0.0)
	local S = C.TurnStage
	local converted_tick = C.__fn.ontick -- StartRampage's own split tick

	function C:TurnBack()
		if self.__turningBack then return end
		self.__turningBack = true
		self:UnregisterForUpdateGameTime()
		self.turnStage = S.WaitSync
		self:OnTick() -- the poll's first check is at once
	end

	function C:OnTick()
		converted_tick(self)
		if self.turnStage == S.Idle then return end
		if self.turnStage == S.WaitSync then
			local player = rt.static("Game", "GetPlayer")
			if player:GetAnimationVariableBool("bIsSynced") then return end
			player:SetGhost(true)
			self.FeedBloodVFX:Stop(player)
			self.WerewolfChange:Apply(1.0)
			self.FadeToBlack:Apply(1.0)
			self.turnStage, self.turnT = S.Fading, self.FadeSeconds
			return
		end
		if self.turnT > 0 then return end
		self.FadeToBlack:PopTo(self.HoldBlack, 1.0)
		rt.static("Game", "SetBeastForm", false)
		rt.static("Game", "EnablePlayerControls", false, false, true, false, false, false, false, false, 1)
		rt.static("Game", "ShowFirstPersonGeometry", true)
		local player = rt.static("Game", "GetPlayer")
		player:UnequipShout(self.CurrentHowl)
		player:RemoveShout(self.CurrentHowl)
		player:SetAttackActorOnSight(false)
		player:RemoveFromFaction(self.PlayerWerewolfFaction)
		player:RemoveFromFaction(self.WerewolfFaction)
		for i = 0, self.CrimeFactions:GetSize() - 1 do
			rt.cast(self.CrimeFactions:GetAt(i), "faction"):SetPlayerEnemy(false)
		end
		rt.static("Game", "SetPlayerReportCrime", true)
		rt.static("Game", "EnableFastTravel", true)
		player:ResetHealthAndLimbs()
		self.CombatMusic:Remove()
		self.PostRampageScene:Start()
		self.turnStage = S.Idle
	end
end
