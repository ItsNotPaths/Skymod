-- pex: teleportaway 02bd4ae9
-- pex: teleportmiraak 5b40800c
-- TeleportAway's dragon-kill branch polled DragonToKill.IsFlying()/IsDead() every 1 s before going
-- on; its off-cliff branch waited 0.2 s. TeleportMiraak itself waited 0.1 s before moving Miraak.
-- Now OnTick carries both: a poll phase for the dragon wait, and TeleportMiraak's own timer, with
-- an extra tail flag for the off-cliff branch's continuation (recovery scene, busy clear) that in
-- Papyrus only ran once TeleportMiraak's own wait had returned.
local rt = require('skymod.rt')

return function(C)
	C.Away = rt.sequence("Idle", "PollDragon", "OffCliffWait")
	C.__vars.awayPhase = C.Away.Idle
	C.__vars.awayT = rt.timer(0.0)
	C.__vars.tmT = rt.timer(0.0)
	C.__vars.tmPending = rt.bool(false)
	C.__vars.tmTarget = rt.form("ObjectReference")
	C.__vars.tmOffCliffTail = rt.bool(false)

	function C:TeleportMiraak(teleportTarget)
		teleportTarget:PlaceAtMe(self.DLC2MiraakBackExplosion)
		self.tmTarget = teleportTarget
		self.tmPending = true
		self.tmT = 0.1 -- fresh wait: TeleportMiraak can be called directly, not only from here
	end

	function C:TeleportAway()
		self.teleportBusy = true
		self.SelfActor:PlaceAtMe(self.DLC2MiraakAwayExplosion)
		self.SelfActor:moveto(self.DLC2MQ06MiraakSaferoom)
		if self.runningMiraakDeathEvent then
			self.SelfActor:EquipItem(self.DLC2MiraakSkeleton)
			self.SelfActor:RemoveSpell(self.DLC2MiraakEtherealFXSpell)
			self.DLC2MiraakStreakE:Stop(self.SelfActor)
			self.SelfActor:MoveTo(self.MQ06MiraakDeathMarker)
			self.DLC2MQ06:SetStage(500)
			self.teleportBusy = false
		elseif self.runningDragonKillEvent then
			self.awayPhase = C.Away.PollDragon
			self:OnTick()
		elseif self.teleportFromOffCliff then
			self.teleportFromOffCliff = false
			self.awayPhase = C.Away.OffCliffWait
			self.awayT = 0.2 -- fresh wait: TeleportAway is an external entry point
		end
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if self.awayPhase == C.Away.PollDragon then
			if self.awayT > 0 then return end
			if self.DragonToKill:IsFlying() and not self.DragonToKill:IsDead() then
				self.awayT = self.awayT + 1.0
				return
			end
			self.awayPhase = C.Away.Idle
			self:GetActorRef():AddSpell(self.DLC2MiraakFakeShoutSpell)
			self.waitingForDragonKillSceneToEnd = true
			self.DLC2MQ06MiraakKillDragonScene:Start()
			self:TeleportMiraak(self.DLC2MiraakFightTeleportMarkerMid)
		elseif self.awayPhase == C.Away.OffCliffWait then
			if self.awayT > 0 then return end
			self.awayPhase = C.Away.Idle
			self.tmOffCliffTail = true
			self:TeleportMiraak(self.DLC2MQ06FightFallTeleportMarker)
		end
		if self.tmPending and self.tmT <= 0 then
			self.tmPending = false
			self.SelfActor:MoveTo(self.tmTarget)
			if not self.SelfActor:IsDead() then
				self.SelfActor:PlaySubgraphAnimation("SkinFadeIn")
			end
			self.teleportBusy = false
			if self.tmOffCliffTail then
				self.tmOffCliffTail = false
				if not self.SelfActor:IsDead() then
					self.DLC2MQ06MiraakFallRecoveryScene:Start()
				end
				self.teleportBusy = false
			end
		end
	end
end
