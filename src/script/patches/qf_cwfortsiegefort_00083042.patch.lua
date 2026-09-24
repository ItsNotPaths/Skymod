-- pex: fragment_0 091a2cd4
-- pex: fragment_4 a3525a93
-- pex: fragment_12 cc635581
-- pex: fragment_20 109e5419
-- Stage 0 polled for DoneSettingUpAliases; shutdown (12) polled every 5 s until the player left
-- the fort, then blocked in WinHoldAndSetOwner or SetNewOwnerOfFort (setOwner); success (20)
-- stopped the quest after WinHoldOffScreenIfNotDoingCapitalBattles. Each now waits on that fact.
-- Same as qf_cwfortsiege_00087c21 except pools, clutter, barricades and the final-hold forts.
-- Fragment_4: no change, only a log line followed StartCWCitizensFlee.
local rt = require('skymod.rt')

return function(C)
	C.Shutdown = rt.sequence("Idle", "AwaitPlayerGone", "AwaitGarrisons")
	local D = C.Shutdown
	local v = C.__vars
	v.aliasesOwed = rt.bool(false) -- stage 0 waits for SetUpAliases
	v.shutdown = D.Idle
	v.stopOwed = rt.bool(false)    -- stage 9000 stops the quest once the hold's resets end
	v.TickRate = rt.float(0.1)
	local Waiting = rt.state(C, "Waiting")

	local function kmy(self) return rt.cast(self, "CWFortSiegeScript") end
	local function mission(self) return rt.cast(self, "CWFortSiegeMissionScript") end
	local function resetting(self) return kmy(self).CWs.resettingGarrisons end

	-- The aliases named prefix1..prefixN, in order, then None up to `slots`.
	local function aliases(self, prefix, n, slots)
		local t = {}
		for i = 1, slots or n do t[i - 1] = i <= n and self[prefix .. i] or rt.None end
		return table.unpack(t, 0, (slots or n) - 1)
	end

	local function each(self, prefix, n, fn, ...)
		for i = 1, n do rt.call(self[prefix .. i], fn, ...) end
	end

	local function register_reinforcements(self)
		local q, m, fort = kmy(self), mission(self), self.Alias_Fort:GetLocation()
		q:RegisterAliasesWithCWReinforcementScript(fort)
		q:RegisterSpawnAttackerAliasesWithCWReinforcementScript(self.Alias_RespawnAttackerPhase1A, self.Alias_RespawnAttackerPhase1B,
			self.Alias_RespawnAttackerPhase1C, self.Alias_RespawnAttackerPhase1D, self.Alias_RespawnAttackerPhase1FailSafe)
		q:RegisterSpawnDefenderAliasesWithCWReinforcementScript(self.Alias_RespawnDefenderPhase1A, self.Alias_RespawnDefenderPhase1B,
			self.Alias_RespawnDefenderPhase1C, self.Alias_RespawnDefenderPhase1D, self.Alias_RespawnDefenderPhase1FailSafe)
		if m.SpecialNonFortSiege == 0 or m.SpecialCapitalResolutionFortSiege == 0 then
			if q.CWs:IsPlayerAttacking(fort) then
				q:SetPoolAttackerOnCWReinforcementScript(40, 1.0, 1.0, true)
				q:SetPoolDefenderOnCWReinforcementScript(40, 1.0, 1.0, false)
			else
				q:SetPoolAttackerOnCWReinforcementScript(30, 1.0, 1.0, false)
				q:SetPoolDefenderOnCWReinforcementScript(30, 1.0, 1.0, true)
			end
		else
			q:SetInfinitePoolsOnCWReinforcementScript()
		end
		q:DisableAllAliases()
		q:RegisterInteriorSpawnerAliases(aliases(self, "Alias_InteriorSpawner", 16))
		q:RegisterInteriorDefenderAliases(aliases(self, "Alias_InteriorDefender", 16))
		q:CreateInteriorDefenders(fort)
		q:DisableInteriorDefenders()
		if m.SpecialNonFortSiege == 1 then -- the final attack inside Solitude or Windhelm: accept at once
			q.CWs:StartCWCitizensFlee(fort)
			self:SetStage(10)
		end
	end

	function C:Fragment_0()
		if self.aliasesOwed then return end
		local q, m = kmy(self), mission(self)
		if m.SpecialNonFortSiege == 0 and m.SpecialCapitalResolutionFortSiege == 0 then
			m:FlagFieldCOWithPotentialMissionFactions(99, false, 0)
			m:ResetCommonMissionProperties()
		elseif m.SpecialCapitalResolutionFortSiege == 1 then
			m:ResetCommonMissionProperties()
		end
		q:RegisterImperialAttackerAliases(aliases(self, "Alias_AttackerImperial", 10))
		q:RegisterSonsAttackerAliases(aliases(self, "Alias_AttackerSons", 10))
		q:RegisterImperialDefenderAliases(aliases(self, "Alias_DefenderImperial", 10))
		q:RegisterSonsDefenderAliases(aliases(self, "Alias_DefenderSons", 10))
		q:RegisterAttackerAliases(aliases(self, "Alias_Attacker", 10))
		q:RegisterDefenderAliases(aliases(self, "Alias_Defender", 10))
		q:RegisterGenericAliases(aliases(self, "Alias_BarricadeNormal", 16, 30))
		self.aliasesOwed = true
		self:GotoState("Waiting")
		q:SetUpAliases(self.Alias_Fort:GetLocation())
		self:OnTick()
	end

	local function aliases_tick(self)
		if not self.aliasesOwed or not kmy(self).DoneSettingUpAliases then return end
		self.aliasesOwed = false
		register_reinforcements(self)
	end

	function C:Fragment_12()
		if self.shutdown ~= D.Idle then return end
		local q, m = kmy(self), mission(self)
		if m.SpecialNonFortSiege == 0 and m.SpecialCapitalResolutionFortSiege == 0 then
			m:ProcessFieldCOFactionsOnQuestShutDown()
		end
		q.CWBattlePhase:SetValue(0)
		q.CWs.CWThreatCombatBarksS:RegisterBattlePhaseChanged()
		self.Alias_MapMarker:GetReference():Enable()
		self.shutdown = D.AwaitPlayerGone
		self:GotoState("Waiting")
		self:OnTick()
	end

	-- Shutdown once the player left the fort, up to the owner change.
	local function hand_over(self)
		local q, m, cws = kmy(self), mission(self), kmy(self).CWs
		local door = self.Alias_JarlsHouseDoor:GetReference()
		if rt.cast(door, "bool") then door:BlockActivation(false) end
		cws:UnregisterEventHappening(self.Alias_Fort:GetLocation())
		local enemies = cws:GetPlayerAllegianceEnemyFaction(true)
		self.Alias_Jarl:GetActorReference():RemoveFromFaction(enemies)
		self.Alias_Housecarl:GetActorReference():RemoveFromFaction(enemies)
		rt.cast(self.Alias_Jarl, "DefaultAliasModAggression"):ResetAggression()
		rt.cast(self.Alias_HouseCarl, "DefaultAliasModAggression"):ResetAggression()
		q:DisableAllAliases()
		q:DisableInteriorDefenders()
		q:DisableBarricades()
		self.shutdown = D.AwaitGarrisons
		if m.SpecialNonFortSiege == 1 or m.SpecialCapitalResolutionFortSiege == 1 then
			cws:StopCWCitizensFlee()
			if m.SpecialCapitalResolutionFortSiege == 1 then
				cws:WinHoldAndSetOwner(self.Alias_Hold:GetLocation(), true, false) -- assumes the attackers won
			end
		else
			q:SetNewOwnerOfFort(1000, 2000)
		end
	end

	-- The rest of the shutdown, once the owner change is done.
	local function clean_up(self)
		local allies = kmy(self).CWs.CWSurrenderTemporaryAllies
		rt.static("Game", "GetPlayer"):RemoveFromFaction(allies)
		self.Alias_Jarl:TryToRemoveFromFaction(allies)
		self.Alias_HouseCarl:TryToRemoveFromFaction(allies)
		each(self, "Alias_Attacker", 10, "TryToRemoveFromFaction", allies)
		each(self, "Alias_Defender", 10, "TryToRemoveFromFaction", allies)
		each(self, "Alias_BarricadeNormal", 16, "TryToReset")
		each(self, "Alias_BarricadeNormal", 16, "TryToEnable")
		mission(self):ToggleOnComplexWIInteractions(self.Alias_Fort)
		kmy(self):DeleteWhenAbleInteriorDefenders() -- last
	end

	local function shutdown_tick(self)
		if self.shutdown == D.AwaitPlayerGone then
			if rt.static("Game", "GetPlayer"):IsInLocation(self.Alias_Fort:GetLocation()) then return end
			hand_over(self)
		end
		if self.shutdown == D.AwaitGarrisons and not resetting(self) then
			self.shutdown = D.Idle
			clean_up(self)
		end
	end

	function C:Fragment_20()
		if self.stopOwed then return end
		local m, cws = mission(self), kmy(self).CWs
		self.stopOwed = true
		self:GotoState("Waiting")
		if m.SpecialNonFortSiege == 0 and m.SpecialCapitalResolutionFortSiege == 0 then
			m:FlagFieldCOWithMissionResultFaction(99, false)
			local hold, fort = self.Alias_Hold:GetLocation(), self.Alias_Fort:GetLocation()
			if fort ~= cws.FortAmolLocation and fort ~= cws.FortHraggstadLocation then
				cws:registerMissionSuccess(hold, true)
				cws:AddCivilWarAchievment(2, fort)
				cws:WinHoldOffScreenIfNotDoingCapitalBattles(hold, true, false)
			else -- a final hold's fort: its siege comes as a mission
				cws:registerMissionSuccess(hold, false)
				if fort == cws.FortAmolLocation then
					cws.EastmarchFortBattleComplete = true
				else
					cws.HaafingarFortBattleComplete = true
				end
			end
		end
		self:OnTick()
	end

	local function stop_tick(self)
		if not self.stopOwed or resetting(self) then return end
		self.stopOwed = false
		self:Stop()
	end

	function Waiting:OnTick()
		aliases_tick(self)
		shutdown_tick(self)
		stop_tick(self)
		if not self.aliasesOwed and self.shutdown == D.Idle and not self.stopOwed then self:GotoState("") end
	end
end
