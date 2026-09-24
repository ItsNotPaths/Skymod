-- pex: fragment_5 0b2896fa 968e584e
-- pex: fragment_25 83742300 7c067929
-- Fragment_5 sets up one city's siege: wait for DoneTurningOnAliases, dispatch per city (Solitude
-- and Windhelm-attack call SetupInteriorSiege and must wait for it), then a shared tail that
-- waits for CWPrepareCity on defense. Three waits become three stages of one field, driven from
-- the class's existing OnTick (S6 split), called first. Fragment_25 needs no change: its own
-- waits are inside FailAttackQuest/SucceedDefenseQuest, both free tails (not in this batch).
local rt = require('skymod.rt')

return function(C)
	C.F5 = rt.sequence("Idle", "WaitAliases", "WaitSetup", "WaitPrepareCity")
	C.__vars.f5stage = C.F5.Idle
	local S = C.F5

	local function kmyQuest(self) return rt.cast(self, "cwsiegescript") end

	-- Camp, reinforcements, catapults, barricade, then per-city dispatch. Returns true if it
	-- started SetupInteriorSiege (caller must then wait for it in WaitSetup).
	local function afterAliases(self, q)
		q.CWs.CWAlliesS:EnableActiveAllies()
		if q.CWs:ImperialsAreAttacking(self.Alias_City:GetLocation()) then
			self.Alias_CampEnableMarkerImperial:GetReference():Enable()
		else
			self.Alias_CampEnableMarkerSons:GetReference():Enable()
		end
		local attacker = q.CWs:GetAttacker(self.Alias_City:GetLocation())
		if attacker == q.CWs.iImperials then
			self.Alias_AttackerImperialReinforceEnabler:GetReference():Enable()
		elseif attacker == q.CWs.iSons then
			self.Alias_AttackerSonsReinforceEnabler:GetReference():Enable()
		end
		self.Alias_BattleCenterMarker:GetReference():Enable()

		local crc = rt.cast(rt.cast(self, "quest"), "cwreinforcementcontrollerscript")
		if q:IsAttack() then
			crc.ShowAttackerPoolObjective = false
			crc.ShowDefenderPoolObjective = false
		else
			crc.ShowAttackerPoolObjective = true
			crc.ShowDefenderPoolObjective = false
		end

		q:TryToTurnOnCatapultAlias(self.Alias_CatapultAttacker1)
		q:TryToTurnOnCatapultAlias(self.Alias_CatapultAttacker2)
		q:TryToTurnOnCatapultAlias(self.Alias_CatapultAttacker3)
		q:TryToTurnOnCatapultAlias(self.Alias_CatapultAttacker4)
		q:TryToTurnOnCatapultAlias(self.Alias_CatapultDefender1)
		q:TryToTurnOnCatapultAlias(self.Alias_CatapultDefender2)
		q:TryToTurnOnCatapultAlias(self.Alias_CatapultDefender3)
		q:TryToTurnOnCatapultAlias(self.Alias_CatapultDefender4)
		self.Alias_MainGateExterior:GetReference():BlockActivation(true)
		rt.cast(self.Alias_Barricade1A, "cwsiegebarricadescript"):ClearGlobals()

		local city = self.Alias_City:GetLocation()
		if city == q.CWs.WhiterunLocation then
			self.MQ106TurnOffRandomDragons:SetValue(1)
			self.Alias_WhiterunBridgeLever1:GetReference():Enable()
			self.Alias_WhiterunBridgeLever2:GetReference():Enable()
			if q:IsAttack() then
				self.Alias_WhiterunIntEnableOnly:GetReference():Enable()
				self.Alias_WhiterunIntDisableOnly:GetReference():Disable()
				q.CWBattlePhase:SetValue(0)
				q.CWAttackerStartingScene:Start()
				self.Alias_WhiterunSeverioPelagia:GetActorReference():Kill()
				self.Alias_WhiterunSeverioPelagia:GetActorReference():MoveToMyEditorLocation()
			else
				self.Alias_DisableFastTravelTrigger:TryToEnable()
				q.CWBattlePhase:SetValue(1)
				q.CWs.CWThreatCombatBarksS:RegisterBattlePhaseChanged()
				self.Alias_ThreatTriggersToggle:TryToEnable()
				q.CWSiegeDefenderStartingScene:Start()
			end
			self.Alias_WhiterunCaravanMarker:GetReference():Disable()
			self.Alias_WhiterunCaravanActor01:GetReference():Disable()
			self.Alias_WhiterunCaravanActor02:GetReference():Disable()
			self.Alias_WhiterunCaravanActor03:GetReference():Disable()
			self.Alias_WhiterunCaravanActor04:GetReference():Disable()
			self.Alias_WhiterunExtEnableOnly:GetReference():Enable()
			self.Alias_WhiterunExtDisableOnly:GetReference():Disable()
			self.Alias_WhiterunDisableNearbyGarrisonEnableMarker1:GetReference():Disable()
			self.Alias_WhiterunDisableNearbyGarrisonEnableMarker2:GetReference():Disable()
			self.Alias_WhiterunDisableNearbyGarrisonEnableMarker3:GetReference():Disable()
			self.Alias_WhiterunDisableNearbyGarrisonEnableMarker4:GetReference():Disable()
			self.Alias_WhiterunDisableNearbyGarrisonEnableMarker5:GetReference():Disable()
			self.Alias_WhiterunDisableNearbyGarrisonEnableMarker6:GetReference():Disable()
			self.Alias_WhiterunDisableNearbyGarrisonEnableMarker7:GetReference():Disable()
			self.Alias_WhiterunDisableNearbyGarrisonEnableMarker8:GetReference():Disable()
			rt.cast(q.DA08, "da08questscript"):WhiterunSiegeHappening(true)
			return false
		elseif city == q.CWs.MarkarthLocation then
			if q:IsAttack() then
				q.CWBattlePhase:SetValue(0)
				q.CWAttackerStartingScene:Start()
			else
				q.CWBattlePhase:SetValue(1)
				q.CWs.CWThreatCombatBarksS:RegisterBattlePhaseChanged()
				self.Alias_ThreatTriggersToggle:TryToEnable()
			end
			self.Alias_MarkarthDisableNearbyGarrisonEnableMarker1:GetReference():Disable()
			self.Alias_MarkarthDisableNearbyGarrisonEnableMarker2:GetReference():Disable()
			self.Alias_MarkarthDisableNearbyGarrisonEnableMarker3:GetReference():Disable()
			self.Alias_MarkarthDisableNearbyGarrisonEnableMarker4:GetReference():Disable()
			return false
		elseif city == q.CWs.RiftenLocation then
			if q:IsAttack() then
				q.CWBattlePhase:SetValue(0)
				q.CWAttackerStartingScene:Start()
			else
				q.CWBattlePhase:SetValue(1)
				q.CWs.CWThreatCombatBarksS:RegisterBattlePhaseChanged()
				self.Alias_ThreatTriggersToggle:TryToEnable()
			end
			self.Alias_RiftenDisableNearbyGarrisonEnableMarker1:GetReference():Disable()
			self.Alias_RiftenDisableNearbyGarrisonEnableMarker2:GetReference():Disable()
			return false
		elseif city == q.CWs.SolitudeLocation then
			if q:IsAttack() then
				q.CWBattlePhase:SetValue(0)
				q.CWAttackerStartingScene:Start()
				self.Alias_Defender1General:GetReference():Disable()
				self.Alias_Defender2:GetReference():Disable()
				self.Alias_Defender3:GetReference():Disable()
				self.Alias_Defender4:GetReference():Disable()
				self.Alias_Defender5:GetReference():Disable()
				self.Alias_Defender6:GetReference():Disable()
				self.Alias_Defender7:GetReference():Disable()
				self.Alias_Defender8:GetReference():Disable()
				self.Alias_Defender9:GetReference():Disable()
				self.Alias_Defender10:GetReference():Disable()
				q.SolitudeOpening:SetStage(200)
				q:SetupInteriorSiege(city, self.Alias_FieldCO:GetReference(), self.Alias_CityCenterMarker:GetReference())
				return true
			end
			q.CWBattlePhase:SetValue(1)
			q.CWs.CWThreatCombatBarksS:RegisterBattlePhaseChanged()
			self.Alias_ThreatTriggersToggle:TryToEnable()
			self.Alias_SolitudeDisableNearbyGarrisonEnableMarker1:GetReference():Disable()
			self.Alias_SolitudeDisableNearbyGarrisonEnableMarker2:GetReference():Disable()
			self.Alias_SolitudeCaravanMarker:GetReference():Disable()
			return false
		elseif city == q.CWs.WindhelmLocation then
			if q:IsAttack() then
				q.CWBattlePhase:SetValue(0)
				q.CWAttackerStartingScene:Start()
				q.MS11:CivilWarBattle(true)
				self.Alias_Defender1General:GetReference():Disable()
				self.Alias_Defender2:GetReference():Disable()
				self.Alias_Defender3:GetReference():Disable()
				self.Alias_Defender4:GetReference():Disable()
				self.Alias_Defender5:GetReference():Disable()
				self.Alias_Defender6:GetReference():Disable()
				self.Alias_Defender7:GetReference():Disable()
				self.Alias_Defender8:GetReference():Disable()
				self.Alias_Defender9:GetReference():Disable()
				self.Alias_Defender10:GetReference():Disable()
				q:SetupInteriorSiege(city, self.Alias_FieldCO:GetReference(), self.Alias_CityCenterMarker:GetReference())
				return true
			end
			q.CWBattlePhase:SetValue(1)
			q.CWs.CWThreatCombatBarksS:RegisterBattlePhaseChanged()
			self.Alias_ThreatTriggersToggle:TryToEnable()
			self.Alias_WindhelmCaravanMarker:GetReference():Disable()
			self.Alias_WindhelmDockGate:GetReference():SetLockLevel(255)
			self.Alias_WindhelmDockGate:GetReference():Lock()
			return false
		end
		return false
	end

	-- The Solitude/Windhelm tail that only runs once SetupInteriorSiege has finished.
	local function afterSetup(self, q)
		local city = self.Alias_City:GetLocation()
		if city == q.CWs.SolitudeLocation then
			self.Alias_SolitudeDisableNearbyGarrisonEnableMarker1:GetReference():Disable()
			self.Alias_SolitudeDisableNearbyGarrisonEnableMarker2:GetReference():Disable()
			self.Alias_SolitudeCaravanMarker:GetReference():Disable()
		elseif city == q.CWs.WindhelmLocation then
			self.Alias_WindhelmCaravanMarker:GetReference():Disable()
			self.Alias_WindhelmDockGate:GetReference():SetLockLevel(255)
			self.Alias_WindhelmDockGate:GetReference():Lock()
		end
	end

	-- Shared "if either attack or defense" tail, every city.
	local function tail(self, q)
		self:RegisterForUpdate(1)
		rt.cast(rt.cast(q, "quest"), "cwsiegepollplayerlocation"):RegisterBattleCenterMarkerAndLocation(
			self.Alias_BattleCenterMarker:GetReference(), self.Alias_City:GetLocation())
		if q:IsAttack() then
			q.CWSiegeObj:SetObjectiveDisplayed(1000, 1)
		else
			q.CWSiegeObj:SetObjectiveDisplayed(2000, 1)
		end
		self.Alias_CatapultDefender1:TryToDisable()
		self.Alias_CatapultDefender2:TryToDisable()
		self.Alias_CatapultDefender3:TryToDisable()
		self.Alias_CatapultDefender4:TryToDisable()
		if q:IsAttack() then
			rt.cast(self.Alias_Attacker1General, "cwsiegegeneralscript"):StartCheckingDistanceToPlayer()
		else
			rt.cast(self.Alias_Defender1General, "cwsiegegeneralscript"):StartCheckingDistanceToPlayer()
		end
	end

	local function finish(self, q)
		q.CWs:AddEnemyFortsToBackToWar()
		self.f5stage = S.Idle
	end

	-- After the tail: attack is done at once, defense waits for CWPrepareCity to start.
	local function afterTail(self, q)
		tail(self, q)
		if q:IsAttack() then
			finish(self, q)
		else
			self.f5stage = S.WaitPrepareCity
		end
	end

	function C:Fragment_5()
		if self.f5stage ~= S.Idle then return end -- a second start is dropped
		local q = kmyQuest(self)
		self.Alias_WhiterunCompanionsTrigger01:GetReference():Disable()
		self.Alias_WhiterunCompanionsTrigger02:GetReference():Disable()
		q:ToggleMapMarkersAndFastTravelStartBattle(q:IsAttack())
		self.Alias_GarrisonEnableMarkerImperialExterior:TryToDisable()
		self.Alias_GarrisonEnableMarkerSonsExterior:TryToDisable()
		q:TurnOnAliases(q:IsAttack())
		self.f5stage = S.WaitAliases
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		local q = kmyQuest(self)
		if self.f5stage == S.WaitAliases then
			if not q.DoneTurningOnAliases then return end
			if afterAliases(self, q) then
				self.f5stage = S.WaitSetup
			else
				afterTail(self, q)
			end
		elseif self.f5stage == S.WaitSetup then
			if q.siegeWaiting then return end
			afterSetup(self, q)
			afterTail(self, q)
		elseif self.f5stage == S.WaitPrepareCity then
			if not q.CWs.CWPrepareCity:IsRunning() then return end
			q.CWs.CWPrepareCity:SetStage(1)
			finish(self, q)
		end
	end
end
