-- pex: fragment_0 52efd410
-- pex: fragment_10 d57528c2
-- pex: fragment_26 b928a80a
-- pex: fragment_33 c398469c 254d00a6
-- pex: fragment_35 fbc1c009
-- pex: fragment_36 32150395 e3555073
-- pex: fragment_38 ec5e59c3
-- The Bthalft battle's stage fragments waited on timers (the forge dust bursts, steam delays),
-- on a kill walk down three linked-ref chains (0.1 s a link), and on Katria's fades
-- (DLC1LD_GhostScript). Each fragment's rest is now a stage stepped by OnTick.
local rt = require('skymod.rt')

return function(C)
	C.F0 = rt.sequence("Idle", "Fading")
	C.F10 = rt.sequence("Idle", "Killing")
	C.F26 = rt.sequence("Idle", "Waiting", "Fading")
	C.F33 = rt.sequence("Idle", "Waiting", "Warping")
	C.F35 = rt.sequence("Idle", "Fading", "Waiting")
	C.F36 = rt.sequence("Idle", "Waiting", "Fading")
	C.F38 = rt.sequence("Idle", "Dust", "Fading")
	local F0, F10, F26, F33, F35, F36, F38 = C.F0, C.F10, C.F26, C.F33, C.F35, C.F36, C.F38
	local v = C.__vars
	v.f0 = F0.Idle
	v.f10, v.f10_t = F10.Idle, rt.timer(0.0)
	v.f10_chain = rt.int(0)                        -- which manager chain the walk is on
	v.f10_at = rt.form("ObjectReference")          -- the next manager on it
	v.f26, v.f26_t = F26.Idle, rt.timer(0.0)
	v.f33, v.f33_t = F33.Idle, rt.timer(0.0)
	v.f35, v.f35_t = F35.Idle, rt.timer(0.0)
	v.f36, v.f36_t = F36.Idle, rt.timer(0.0)
	v.f38, v.f38_t = F38.Idle, rt.timer(0.0)
	v.f38_burst = rt.int(0)                        -- the next dust burst
	v.TickRate = rt.float(0.1)
	local split_tick = C.__fn.ontick

	-- ForgeDustFX indices per burst, and the wait after each
	local BURSTS = { { 4, 10, 15 }, { 8, 1 }, { 12, 6, 9 }, { 13 }, { 0, 3, 1 }, { 11, 14 } }
	local AFTER = { 0.1, 0.2, 0.1, 0.3, 0.1, 2.0 }

	local function player() return rt.static("Game", "GetPlayer") end
	local function katria(self) return rt.cast(self.Alias_Katria:GetActorRef(), "DLC1LD_GhostScript") end
	local function katria_settled(self)
		local k = katria(self)
		return not k or k.fade.name == "Idle"
	end
	local function katria_here(self) return self.DLC1LD:GetStageDone(130) end
	local function fade_in_if_hidden(self)
		local k = katria(self)
		if k:IsDisabled() then k:FadeIn() end
	end

	function C:Fragment_0()
		if self.f0 ~= F0.Idle then return end
		if not katria_here(self) then
			self.Alias_Forgemaster:GetActorRef():Disable()
			return
		end
		local k = katria(self)
		self.f0 = F0.Fading
		k:Disable()
		k:MoveTo(self.KatriaBthalftExteriorMarker)
		k.KatriaTeleportingOut = false
		k:FadeIn()
	end

	local function f0_tick(self)
		if self.f0 ~= F0.Fading or not katria_settled(self) then return end
		self.f0 = F0.Idle
		local k = katria(self)
		k:EvaluatePackage()
		k:SetGhost(false)
		self.DLC1LD:SetStage(160)
		self.Alias_Forgemaster:GetActorRef():Disable()
	end

	function C:Fragment_10()
		if self.f10 ~= F10.Idle then return end
		self.DLC1LD:SetStage(210)
		self.AetheriumForgeFurniture:Enable()
		if katria_here(self) then
			if katria(self):IsDisabled() then katria(self):FadeInNoWait() end
			self.DLC1LD_Katria_Forge07:Start()
		end
		for _, fx in ipairs({ self.DLC1LD_FXSteamCenter, self.DLC1LD_FXSteamLeft, self.DLC1LD_FXSteamRight, self.DLC1LD_FXSteamForge }) do
			rt.cast(fx, "DLC1LD_BthalftSteamManagerScript"):DisableSteam()
		end
		rt.cast(self.ValveLeft, "DLC1LD_ForgeSteamValveScript"):GotoState("Animating")
		rt.cast(self.ValveRight, "DLC1LD_ForgeSteamValveScript"):GotoState("Animating")
		self:SetStage(59)
		rt.cast(self.BattleSpider01, "Actor"):Kill()
		self.f10 = F10.Killing
		self.f10_chain = 0
		self.f10_at = self.SpiderManager
		self.f10_t = 0.0
		self:OnTick()
	end

	-- one manager's enemy per 0.1 s, chain after chain; the reward 0.1 s after the last
	local function f10_tick(self)
		if self.f10 ~= F10.Killing or self.f10_t > 0 then return end
		local chains = { self.SpiderManager, self.SpiderManager2, self.SphereManager }
		while not self.f10_at do
			if self.f10_chain >= #chains - 1 then
				self.f10 = F10.Idle
				self.MUSReward:Add()
				return
			end
			self.f10_chain = self.f10_chain + 1
			self.f10_at = chains[self.f10_chain]
		end
		local manager = self.f10_at
		self.f10_at = manager:GetLinkedRef()
		self.f10_t = self.f10_t + 0.1
		local enemy = manager:GetLinkedRef(self.LinkCustom01)
		if enemy then rt.cast(enemy, "Actor"):Kill() end
	end

	function C:Fragment_26()
		if self.f26 ~= F26.Idle then return end
		self.f26 = F26.Waiting
		self.f26_t = 5.0
	end

	local function f26_tick(self)
		if self.f26 == F26.Waiting and self.f26_t <= 0 then
			self.f26 = F26.Idle
			if self:GetStageDone(75) then return end
			if not katria_here(self) then return self:SetStage(62) end
			self.f26 = F26.Fading
			fade_in_if_hidden(self)
		end
		if self.f26 == F26.Fading and katria_settled(self) then
			self.f26 = F26.Idle
			self.DLC1LD_Katria_Forge06b:Start()
		end
	end

	function C:Fragment_33()
		if self.f33 ~= F33.Idle then return end
		if katria_here(self) then self.DLC1LD:SetStage(200) end
		self.BattleSpider01:Enable(false)
		self.BattleSpider01:Activate(self.SpiderManager)
		local combat = rt.cast(self.SpiderManager, "dunProgressiveCombatScript")
		local link = combat.BattleManager
		while link do
			link:GetLinkedRef(self.LinkCustom01):Enable(false)
			link = link:GetLinkedRef()
		end
		combat:Activate(self.SpiderManager)
		if not katria_here(self) then return end
		self.f33 = F33.Waiting
		self.f33_t = 1.0
	end

	local function f33_tick(self)
		if self.f33 == F33.Waiting and self.f33_t <= 0 then
			self.f33 = F33.Warping
			local k, p = katria(self), player()
			if p:GetDistance(k) > 1200 then k:Warp(p) end
		end
		if self.f33 == F33.Warping and katria_settled(self) then
			self.f33 = F33.Idle
			self.DLC1LD_Katria_Forge03:Start()
		end
	end

	function C:Fragment_35()
		if self.f35 ~= F35.Idle then return end
		self.SphereGate1:SetOpen()
		self.SphereGate2:SetOpen()
		if not katria_here(self) then
			self.f35 = F35.Waiting
			self.f35_t = 10.0
			return
		end
		self.f35 = F35.Fading
		fade_in_if_hidden(self)
		self:OnTick()
	end

	local function f35_tick(self)
		if self.f35 == F35.Fading and katria_settled(self) then
			self.f35 = F35.Waiting
			self.f35_t = 10.0
			self.DLC1LD_Katria_Forge04:Start()
		end
		if self.f35 == F35.Waiting and self.f35_t <= 0 then
			self.f35 = F35.Idle
			self:SetStage(57)
		end
	end

	function C:Fragment_36()
		if self.f36 ~= F36.Idle then return end
		for _, fx in ipairs({ self.DLC1LD_FXSteamCenter, self.DLC1LD_FXSteamLeft, self.DLC1LD_FXSteamRight }) do
			rt.cast(fx, "DLC1LD_BthalftSteamManagerScript"):EnableSteam()
		end
		self.f36 = F36.Waiting
		self.f36_t = 2.0
	end

	local function f36_tick(self)
		if self.f36 == F36.Waiting and self.f36_t <= 0 then
			self.f36 = F36.Idle
			self:SetStage(58)
			if not katria_here(self) then return end
			self.f36 = F36.Fading
			fade_in_if_hidden(self)
		end
		if self.f36 == F36.Fading and katria_settled(self) then
			self.f36 = F36.Idle
			if not self:GetStageDone(59) then self.DLC1LD_Katria_Forge05:Start() end
		end
	end

	local function dust_burst(self, i)
		for _, fx in ipairs(BURSTS[i]) do rt.aget(self.ForgeDustFX, fx):OnActivate(player()) end
	end

	function C:Fragment_38()
		if self.f38 ~= F38.Idle then return end
		rt.cast(self.Alias_Forgemaster, "DLC1LD_ForgemasterBossBattle"):StartForgemaster()
		self.Alias_Forgemaster:GetActorRef():StartCombat(player())
		self.AmbRumbleShake:Play(player())
		player():RampRumble(1, 2, 1600)
		rt.static("Game", "ShakeCamera", rt.None, 0.75, 2)
		self.MUSDread:Add()
		self.f38 = F38.Dust
		self.f38_burst = 1
		self.f38_t = AFTER[0]
		dust_burst(self, 0)
	end

	local function f38_tick(self)
		if self.f38 == F38.Dust and self.f38_t <= 0 then
			local i = self.f38_burst
			if i < #BURSTS then
				self.f38_burst = i + 1
				self.f38_t = self.f38_t + AFTER[i]
				return dust_burst(self, i)
			end
			if not katria_here(self) then
				self.f38 = F38.Idle
				return self:SetStage(61)
			end
			self.f38 = F38.Fading
			fade_in_if_hidden(self)
		end
		if self.f38 == F38.Fading and katria_settled(self) then
			self.f38 = F38.Idle
			self.DLC1LD_Katria_Forge06:Start()
			self:SetStage(61)
		end
	end

	-- the split fragments first; Katria's fades end in her own tick
	function C:OnTick()
		split_tick(self)
		f0_tick(self)
		f10_tick(self)
		f26_tick(self)
		f33_tick(self)
		f35_tick(self)
		f36_tick(self)
		f38_tick(self)
	end
end
