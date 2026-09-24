-- pex: fragment_20 50b0fb99
-- pex: fragment_21 a4b7b4c8
-- pex: fragment_32 26b611b9
-- Stage 20 summoned the frost boss 2 s after its scene and made it hostile 2 s after the summon
-- ended. Stage 21 ran the ritual: a 2 s charge, the altar's Stage2 animation, a 0.5 s white-out,
-- then the knockdown. Stage 32 banished the boss once the wave's count had finished, and hid
-- it 0.5 s later. Each is a stage here, stepped by OnTick next to the split fragments' ticks.
local rt = require('skymod.rt')

return function(C)
	C.F20 = rt.sequence("Idle", "Scene", "Summoning", "Joining")
	C.F21 = rt.sequence("Idle", "Charging", "Ritual", "WhiteOut")
	C.F32 = rt.sequence("Idle", "Counting", "Banishing")
	C.__vars.f20 = C.F20.Idle
	C.__vars.f20_t = rt.timer(0.0)
	C.__vars.f20_boss = rt.form("defaultFakeSummonSpell")
	C.__vars.f21 = C.F21.Idle
	C.__vars.f21_t = rt.timer(0.0)
	C.__vars.f32 = C.F32.Idle
	C.__vars.f32_t = rt.timer(0.0)
	C.__vars.f32_wave = rt.form("DLC1_BF_WaveControllerSCRIPT")
	C.__vars.f32_boss = rt.form("defaultFakeSummonSpell")
	local F20, F21, F32 = C.F20, C.F21, C.F32
	local split_tick = C.__fn.ontick

	local function quest(self) return rt.cast(self, "dlc1_bf_duntempleqstscript") end
	local function player() return rt.static("Game", "GetPlayer") end

	-- the first frost boss alias that holds a ref, as each if/elseif chain picked it
	local function boss_alias(self)
		for i = 1, 5 do
			local a = self["Alias_FrostMiniBoss0" .. i]
			if a:GetReference() then return a end
		end
	end

	function C:Fragment_20()
		if self.f20 ~= F20.Idle then return end
		quest(self).DLC1_BF_DunTempleQSTScene02:Start()
		self.f20 = F20.Scene
		self.f20_t = 2.0
	end

	local function f20_tick(self)
		if self.f20 == F20.Scene and self.f20_t <= 0 then
			local a = boss_alias(self)
			self.f20_boss = a and a:GetReference() or rt.None
			if self.f20_boss then self.f20_boss:Summon() end
			self.f20 = F20.Summoning
		end
		if self.f20 == F20.Summoning then
			if self.f20_boss and self.f20_boss.summoning ~= rt.None then return end
			if self.f20_boss then self.f20_boss:MoveToMyEditorLocation() end
			self.f20 = F20.Joining
			self.f20_t = 2.0
		elseif self.f20 == F20.Joining and self.f20_t <= 0 then
			self.f20 = F20.Idle
			local a = boss_alias(self)
			if a then a:GetActorReference():AddToFaction(quest(self).DaedraFaction) end
			quest(self).DLC1VampireLordDisallow:SetValue(1)
		end
	end

	function C:Fragment_21()
		if self.f21 ~= F21.Idle then return end
		local q = quest(self)
		self:SetStage(720) -- ceiling collapses stop at 720
		q.MUSCombat:Remove()
		self.DLC1SnowElfTelekinesisHandLEffect:Play(self.Alias_Prince:GetReference())
		self.Alias_Prince:GetActorReference():EvaluatePackage()
		q.DLC1_BF_DunTempleQSTScene03:Start()
		self.f21 = F21.Charging
		self.f21_t = 2.0
	end

	local function f21_tick(self)
		local q = quest(self)
		local prince = self.Alias_Prince:GetActorReference()
		if self.f21 == F21.Charging and self.f21_t <= 0 then
			q.FXRumbleFalmerBoss2D:Play(prince)
			self.DLC01_SunAuraCloakEffect:Play(prince)
			prince:SetSubGraphFloatVariable("ftoggleBlend", 1.0)
			prince:PlayIdle(q.idleRitualSpellStart)
			rt.static("Game", "ShakeController", 0.3, 0.3, 8)
			rt.static("Game", "ShakeCamera", player(), 0.3, 8)
			q.RitualCharge:ApplyCrossfade(8)
			rt.static("Game", "DisablePlayerControls", false, true, true, false, true, true)
			q.DLC1_BF_DunTempleQSTSCENEShiftBack:Start()
			self.Alias_TempFinale2:GetReference():PlayAnimation("Stage2")
			self.Alias_TempFinale:GetReference():PlayAnimation("Stage2")
			self.f21 = F21.Ritual
		elseif self.f21 == F21.Ritual and not self.Alias_TempFinale:GetReference():IsAnimRunning("Stage2") then
			local trig = rt.cast(self.Alias_ZombieDragonNoFlyTrig:GetReference(), "DLC1DurnehviirNoFlyingTrigSCRIPT")
			if trig.triggerDragonRef then rt.cast(trig.triggerDragonRef, "Actor"):SetAllowFlying(true) end
			trig.DLC1DurnehviirDisallowFlying:SetValue(0)
			self.Alias_ZombieDragonNoFlyTrig:GetReference():DisableNoWait()
			q.SunDamageExceptionWorldSpaces:RemoveAddedForm(q.DLC01FalmerValley)
			self.Alias_VisBlockers:GetReference():Disable()
			self.Alias_Prince:GetActorRef():SetGhost(true)
			self.Alias_Serana:GetActorRef():SetGhost(true)
			prince:PlayIdle(q.idleRitualSpellRelease)
			q.DLC1_BF_DunTempleQSTSceneKnockdown:Start()
			self.Alias_BossIceSpikes:GetReference():DisableNoWait()
			rt.static("Game", "ShakeController", 0.7, 0.7, 4)
			rt.static("Game", "ShakeCamera", player(), 1, 4)
			prince:KnockAreaEffect(1, 3000)
			self.DLC01_SunAuraCloakEffect:Stop(prince)
			prince:SetSubGraphFloatVariable("ftoggleBlend", 0.0)
			self.Alias_BossFightLights:GetReference():DisableNoWait()
			q.FullWhite:ApplyCrossfade(0.5)
			self.f21 = F21.WhiteOut
			self.f21_t = 0.5
		elseif self.f21 == F21.WhiteOut and self.f21_t <= 0 then
			self.f21 = F21.Idle
			player():MoveTo(self.Alias_PlayerKnockdownMarker:GetReference())
			rt.static("Game", "DisablePlayerControls", true, true, true, true, true, true)
			rt.static("Game", "EnableFastTravel", false)
			rt.static("ImageSpaceModifier", "RemoveCrossfade", 3.0)
			self.Alias_Serana:GetReference():MoveTo(self.Alias_SeranaKnockdownMarker:GetReference())
			rt.static("Game", "ForceFirstPerson")
			player():PlayIdle(q.TG05_KnockOut)
			rt.cast(self.Alias_DebrisController:GetReference(), "DLC1_BF_FallingDebrisControllerSCRIPT"):TryToDisableLightBeams()
			rt.static("Weather", "ReleaseOverride")
			self:SetStage(800)
		end
	end

	function C:Fragment_32()
		if self.f32 ~= F32.Idle then return end
		self.f32_wave = self.Alias_WaveMarker03b:GetReference()
		self.f32_wave:CountDead()
		self.f32 = F32.Counting
		self:OnTick()
	end

	local function f32_tick(self)
		if self.f32 == F32.Counting then
			if self.f32_wave and self.f32_wave.counting.name ~= "Idle" then return end
			local a = boss_alias(self)
			self.f32_boss = a and a:GetReference() or rt.None
			if not self.f32_boss then
				self.f32 = F32.Idle
				return
			end
			self.f32_boss:Banish()
			self.f32 = F32.Banishing
			self.f32_t = 0.5
		elseif self.f32 == F32.Banishing and self.f32_t <= 0 then
			self.f32 = F32.Idle
			self.f32_boss:DisableNoWait()
		end
	end

	function C:OnTick()
		split_tick(self)
		f20_tick(self)
		f21_tick(self)
		f32_tick(self)
	end
end
