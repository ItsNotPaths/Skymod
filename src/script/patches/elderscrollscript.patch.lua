-- pex: onequipped 88110660
-- OnEquipped ran a long chain of Utility.Wait between reads. Now a stage of rt.sequence per branch
-- (time travel vs. blind) plus a stopwatch; OnTick advances one step when its wait is due. The
-- event closes its own menu (script-api.md section 7).
local rt = require('skymod.rt')

local function trace(self, msg) rt.static("Debug", "Trace", tostring(self) .. " " .. msg) end

return function(C)
	C.__exits_menu = { OnEquipped = true } -- (hole exits-menu :tags (ui script) :sev gap) nothing reads __exits_menu: the read waits until the player closes the inventory
	-- each stage names the step that runs when `wait` runs out; Travel* is the MQ206 time-travel
	-- read, Blind* the normal read
	C.Read = rt.sequence("Idle",
		"TravelRead", "TravelReadSound", "TravelSound", "TravelWarp", "TravelMusic", "TravelFade",
		"TravelJump", "TravelIdleStop", "TravelFadeOut",
		"BlindIn", "BlindShake", "BlindIdleStop", "BlindOut")
	C.__vars.read = C.Read.Idle
	C.__vars.wait = rt.timer(0.0)
	C.__vars.reader = rt.form("Actor")

	-- MusicType forms read as ObjectReference (class_of), so `m:Add()` is a name error; rt.call warns
	local function add_music(self) rt.call(self.MUSSpecialElderScrollSquence, "Add") end

	function C:OnEquipped(akActor)
		if akActor ~= rt.static("Game", "GetPlayer") then return end
		if self.read ~= C.Read.Idle then
			trace(self, "OnEquipped: already reading, dropped")
			return
		end
		self.reader = akActor
		local waitForUnequip = akActor:GetEquippedItemType(0) > 0 or akActor:GetEquippedItemType(1) > 0
		-- the stage is set before the first action, so an error below cannot let a second equip restart
		if self.TimeWoundTrigger:IsTriggerReady() and not self.MQ206:GetStageDone(20) and akActor:GetSitState() == 0 then
			self.read, self.wait = C.Read.TravelRead, waitForUnequip and 2.0 or 0.0
			trace(self, "OnEquipped: time travel")
			rt.static("Game", "DisablePlayerControls", true, true, true, false, true, true, true, true, 0)
			rt.static("Game", "ForceFirstPerson")
			add_music(self)
		else
			local sitting = akActor:GetSitState() ~= 0
			self.read, self.wait = C.Read.BlindIn, sitting and 0.0 or 1.05
			trace(self, "OnEquipped: go blind")
			rt.static("Game", "DisablePlayerControls", false, false, false, false, false, true, false, false, 0)
			if not sitting then
				rt.static("Game", "ForceFirstPerson")
				akActor:EquipItem(self.ElderScrollHandAttachArmor, false, true)
				akActor:PlayIdle(self.idleReadElderScroll)
			end
		end
		self:OnTick()
	end

	function C:OnTick()
		if self.read == C.Read.Idle or self.wait > 0 then return end
		local S, step, a = C.Read, self.read, self.reader
		if step == S.TravelRead then
			self.read, self.wait = S.TravelReadSound, 0.5
			a:EquipItem(self.ElderScrollHandAttachArmor, false, true)
			a:PlayIdle(self.IdleReadElderScroll)
			a:DispelAllSpells()
		elseif step == S.TravelReadSound then
			self.read, self.wait = S.TravelSound, 0.75
			self.QSTMQ206ElderScrollRead2DSound:Play(a)
		elseif step == S.TravelSound then
			self.read, self.wait = S.TravelWarp, 0.75
			self.QSTMQ206TimeTravel2DSound:Play(a)
		elseif step == S.TravelWarp then
			self.read, self.wait = S.TravelMusic, 1.25
			self.FXTimeWarpCamAttachEffect:Play(a, -1.0, None)
		elseif step == S.TravelMusic then
			self.read, self.wait = S.TravelFade, 1.75
			add_music(self)
		elseif step == S.TravelFade then
			self.read, self.wait = S.TravelJump, 1.0
			self.FadeToWhiteInOutImod:Apply(1.0)
		elseif step == S.TravelJump then
			self.read, self.wait = S.TravelIdleStop, 4.0
			self.MQ206:SetStage(20)
			self.SkyrimMQ206weather:SetActive(true, false)
			self.FXTimeTravelCamAttachEffect:Play(a, -1.0, None)
			self.FXTimeTravelImodStatic:ApplyCrossFade(0.05)
		elseif step == S.TravelIdleStop then
			self.read, self.wait = S.TravelFadeOut, 5.0
			a:PlayIdle(self.IdleStop)
			a:RemoveItem(self.ElderScrollHandAttachArmor, 1, true, None)
		elseif step == S.TravelFadeOut then
			self.read = S.Idle
			self.FXTimeTravelImodStatic02:ApplyCrossFade(5.0)
		elseif step == S.BlindIn then
			self.read, self.wait = S.BlindShake, 0.5
			self.soundInstance01 = self.OBJElderScrollBlindIn2D:Play(a)
		elseif step == S.BlindShake then
			self.read, self.wait = S.BlindIdleStop, 3.0 -- wait(1) then wait(2)
			rt.static("Game", "ShakeCamera", None, 0.5, 1.5)
			self.FXReadElderScrollEffect:Play(a, 8.1, None)
			self.FXReadScrollsBlindImod:Apply(1.0)
		elseif step == S.BlindIdleStop then
			self.read, self.wait = S.BlindOut, 1.9
			if a:GetSitState() == 0 then
				a:PlayIdle(self.IdleStop)
				a:RemoveItem(self.ElderScrollHandAttachArmor, 1, true, None)
			end
			rt.static("Game", "EnablePlayerControls", false, false, false, false, false, true, false, false, 0)
		elseif step == S.BlindOut then
			self.read = S.Idle
			self.soundInstance02 = self.OBJElderScrollBlindOut2D:Play(a)
		end
		trace(self, "OnEquipped step " .. tostring(step))
	end
end
