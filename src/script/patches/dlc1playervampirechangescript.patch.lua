-- pex: shiftback 88a7521d
-- pex: actuallyshiftbackifnecessary e8e5eae9
-- pex: onanimationevent e41b841d
-- ShiftBack polled bIsSynced every 0.1 s, then ActuallyShiftBackIfNecessary turned the Vampire
-- Lord back: it waited for PlayerVampireQuest.VampireProgression (a 2 s fade) and ended on a 5 s
-- wait. It is now the run `back`, stepped by OnTick in "Busy"; callers wait while it is not Idle.
-- OnAnimationEvent needs no change: its TransformToHuman branch is the only one that starts the run.
local rt = require('skymod.rt')

return function(C)
	C.Back = rt.sequence("Idle", "Synced", "Progressing", "Settling")
	local B = C.Back
	C.__vars.back, C.__vars.back_t = B.Idle, rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Busy = rt.state(C, "Busy")

	local function player() return rt.static("Game", "GetPlayer") end
	local function busy(self)
		if self:GetState() ~= "Busy" then self:GotoState("Busy") end
	end

	function C:ShiftBack()
		self.__tryingToShiftBack = true
		if self.back ~= B.Idle then return end
		self.back = B.Synced
		busy(self)
		self:OnTick()
	end

	function C:ActuallyShiftBackIfNecessary()
		local p = player()
		if self.__shiftingBack then return end
		self.__shiftingBack = true
		p:GetActorBase():SetInvulnerable(true)
		p:SetGhost(true)
		if not self.DLC1HasLightfoot then p:RemovePerk(self.Lightfoot) end
		self:UnregisterForEvents()
		self.DCL1VampireLevitateStateGlobal:SetValue(1)
		rt.static("Game", "SetInCharGen", true, true, false)
		self:UnregisterForUpdate()
		if p:IsDead() then return end
		self.back = B.Progressing
		busy(self)
		self.VampireChange:Apply()
		self.VampireIMODSound:Play(p)
		self.DLC1VampireChangeBackFXS:Play(p, 12.0)
		local dispel = self.VampireDispelList
		for i = 0, dispel:GetSize() - 1 do
			local gone = rt.cast(dispel:GetAt(i), "Spell")
			if gone then p:DispelSpell(gone) end
		end
		self.CurrentEquippedLeftSpell = p:GetEquippedSpell(0)
		local generic = rt.cast(self.DialogueGenericVampire, "VampireQuestScript")
		generic.LastLeftHandSpell = self.CurrentEquippedLeftSpell
		if p:GetEquippedSpell(2) == self.DLC1Revert then
			generic.LastPower = self.DLC1VampireBats
		else
			generic.LastPower = p:GetEquippedSpell(2)
		end
		for _, s in ipairs({ self.LeveledDrainSpell, self.LeveledAbility, self.LeveledRaiseDeadSpell, self.DLC1VampiresGrip,
			self.DLC1ConjureGargoyleLeftHand, self.DLC1CorpseCurse, self.DLC1VampireDetectLife, self.DLC1VampireMistForm,
			self.DLC1VampireBats, self.DLC1SupernaturalReflexes, self.DLC1NightCloak, self.DLC1Revert, self.DLC1VampireLordSunDamage }) do
			p:RemoveSpell(s)
		end
		for _, s in ipairs({ self.DLC1VampireDetectLife, self.DLC1VampireMistForm, self.DLC1SupernaturalReflexes, self.DLC1Revert, self.VampireHuntersSight }) do
			p:DispelSpell(s)
		end
		p:RemoveSpell(self.DLC1AbVampireFloatBodyFX)
		for _, g in ipairs({ self.pDLC1nVampireNecklaceBats, self.pDLC1nVampireNecklaceGargoyle, self.pDLC1nVampireRingBeast, self.pDLC1nVampireRingErudite }) do
			g:SetValue(0)
		end
		self.PlayerVampireQuest:VampireProgression(p, self.PlayerVampireQuest.VampireStatus)
	end

	-- the rest of ActuallyShiftBackIfNecessary, once the progression's fade is over
	local function change_back(self)
		local p = player()
		local health = p:GetAV("Health")
		if health <= 70 then p:RestoreAV("Health", 70 - health) end
		p:RemoveItem(self.DLC1VampireLordArmor, 2, true)
		p:SetRace(rt.cast(self.VampireTrackingQuest, "DLC1VampireTrackingQuest").PlayerRace)
		self.DLC1VampireChangeBackFXS:Stop(p)
		self.DLC1VampireChangeBack02FXS:Play(p, 0.1)
		rt.static("Game", "ShowFirstPersonGeometry", true)
		p:SetAttackActorOnSight(false)
		self.HunterFaction:SetPlayerEnemy(false)
		p:RemoveFromFaction(self.PlayerVampireFaction)
		for i = 0, self.CrimeFactions:GetSize() - 1 do
			rt.cast(self.CrimeFactions:GetAt(i), "Faction"):SetPlayerEnemy(false)
		end
		rt.static("Game", "SetPlayerReportCrime", true)
	end

	function Busy:OnTick()
		if self.back == B.Synced then
			if player():GetAnimationVariableBool("bIsSynced") then return end
			self.back = B.Idle -- ActuallyShiftBackIfNecessary starts the next stage unless it bails out
			self.__shiftingBack = false
			self:ActuallyShiftBackIfNecessary()
		end
		if self.back == B.Progressing then
			if self.PlayerVampireQuest.prog.name ~= "Idle" then return end
			self.back = B.Settling
			self.back_t = 5.0 -- give the set race event a chance to come back
			change_back(self)
		end
		if self.back == B.Settling and self.back_t <= 0 then self.back = B.Idle end
		if self.back == B.Idle then self:GotoState("") end
	end
end
