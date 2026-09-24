-- pex: doaction a3ea7838
-- pex: empty.onactivate 2e3db137
-- pex: filled.onactivate 5eca0c7c
-- pex: insertcubeneloth 11190515
-- pex: insertcubeplayer f4c7d8cc
-- pex: onload b7871161
-- pex: playfx 71d9995f
-- pex: removecubeneloth 7f0525a1
-- pex: removecubeplayer 7a11774e
-- pex: resetextrudepedestal b481bfc6
-- pex: undoaction 332f788b
-- An Nchardak pedestal takes or returns a cube. An extrude pedestal acts 0.75 s after its move and
-- is empty again 0.75 s + AdditionalReturnDelay later; a hold pedestal updates the objective after
-- 0.5 s, acts (which may start or stop the boiler), rumbles (PlayFX, 0 / 1 / 3.25 s), acts again
-- and settles after AdditionalReturnDelay. Now `run` steps those in Busy, `fx` is the rumble, and
-- the run waits for the boiler's own run. DoAction and UndoAction need no change: their only wait
-- was the boiler's, which the run waits for. `asked_by` is the aqueduct controller that asked for
-- the insertion; it is told when the cube is in, as Papyrus did after InsertCubePlayer returned.
local rt = require('skymod.rt')

return function(C)
	C.Run = rt.sequence("Idle", "ExtrudeAct", "ExtrudeActing", "ExtrudeGive", "ExtrudeReturn", "Objective", "Acting", "Effects", "Returning", "Resetting")
	C.Fx = rt.sequence("Idle", "Rumble", "Pause", "Shaking")
	local R, F = C.Run, C.Fx
	local v = C.__vars
	v.run, v.run_t = R.Idle, rt.timer(0.0)
	v.fx, v.fx_t = F.Idle, rt.timer(0.0)
	v.removing = rt.bool(false)     -- the hold run takes the cube out
	v.by_player = rt.bool(false)    -- the player moves the cube (Neloth's quest moves it otherwise)
	v.extrude_undo = rt.bool(false) -- the extrude run undoes its action
	v.asked_by = rt.form("ObjectReference")
	v.TickRate = rt.float(0.05)
	local Empty, Filled, Busy = rt.state(C, "Empty"), rt.state(C, "Filled"), rt.state(C, "Busy")

	local function tracking(self) return rt.cast(self.DLC2dunNchardakTracking, "DLC2dunNchardakTrackingScript") end
	local function player() return rt.static("Game", "GetPlayer") end
	local function boiler_busy(self)
		local b = self.Act_Boiler and rt.cast(self.Act_Boiler, "DLC2dunNchardakBoilerFX")
		return b and b.boiler.name ~= "Idle"
	end

	local function settle(self, state)
		self.run = R.Idle
		self:GotoState(state)
		local who = self.asked_by
		if who then
			self.asked_by = rt.None
			rt.cast(who, "DLC2dunNchardakAqueductController"):ActivationComplete()
		end
	end

	local function extrude(self, by_player)
		self.by_player = by_player
		if by_player then tracking(self):TakeACube(false) end
		self.extrude_undo = self.nextEventIsBackward
		if self.extrude_undo then
			self:PlayAnimation("Backward")
			self.nextEventIsBackward = false
			if by_player then self:UndoActionInstant() end
		else
			self:PlayAnimation("Forward")
			self.nextEventIsBackward = true
			if by_player then self:DoActionInstant() end
		end
		self.run = R.ExtrudeAct
		self.run_t = 0.75
	end

	local function hold(self, by_player, removing)
		self.by_player, self.removing = by_player, removing
		if removing then
			self:PlayAnimation("Backward")
			self:UndoActionInstant()
		else
			if by_player then tracking(self):TakeACube(true) end
			self:PlayAnimation("Forward")
			self:DoActionInstant()
		end
		self.run = R.Objective
		self.run_t = 0.5
	end

	function C:InsertCubePlayer()
		self:GotoState("Busy")
		if not self.shouldExtrude then return hold(self, true, false) end
		if self.nextEventIsBackward and self.ifExtrudeUseOnlyOnce then
			return self.FailureMessageAlreadyOpen:Show() -- stays Busy, as in Papyrus
		end
		extrude(self, true)
	end

	function C:InsertCubeNeloth()
		self:GotoState("Busy")
		if self.shouldExtrude then return extrude(self, false) end
		hold(self, false, false)
	end

	function C:RemoveCubePlayer()
		self:GotoState("Busy")
		hold(self, true, true)
	end

	function C:RemoveCubeNeloth()
		if self:GetState() ~= "Filled" then return false end
		self:GotoState("Busy")
		hold(self, false, true)
		return true
	end

	function C:ResetExtrudePedestal()
		if not self.nextEventIsBackward then return end
		self:GotoState("Busy")
		self:PlayAnimation("Backward")
		self.nextEventIsBackward = false
		self.run = R.Resetting
		self.run_t = 1.5 + self.AdditionalReturnDelay
	end

	function C:PlayFX()
		local n = self.RumbleShakeIntensity
		if n ~= 1 and n ~= 2 then return end
		self.AMBRumbleShakeGreybeards:Play(self)
		if n == 1 then
			rt.static("Game", "ShakeCamera", self, 0.15, 1)
			player():RampRumble(0.15, 1, 1600)
			self.fx, self.fx_t = F.Rumble, 1.0
		else
			self.fx, self.fx_t = F.Pause, 0.25
		end
	end

	local function fx_tick(self)
		if self.fx == F.Idle or self.fx_t > 0 then return end
		if self.fx == F.Pause then
			player():RampRumble(0.15, 1.5, 1600)
			rt.static("Game", "ShakeCamera", self, 0.15, 1.5)
			self.fx = F.Shaking
			self.fx_t = self.fx_t + 3.0
			return
		end
		self.fx = F.Idle
	end

	local run_tick
	function run_tick(self)
		if self.run == R.Idle or self.run_t > 0 then return end
		if self.run == R.ExtrudeAct then
			if self.extrude_undo then self:UndoAction(0) else self:DoAction(0) end
			self.run = R.ExtrudeActing
			return run_tick(self)
		elseif self.run == R.ExtrudeActing then
			if boiler_busy(self) then return end
			self.run = R.ExtrudeGive
			self.run_t = 0.75
		elseif self.run == R.ExtrudeGive then
			if self.by_player then tracking(self):GiveACube(false) end
			self.run = R.ExtrudeReturn
			self.run_t = self.run_t + self.AdditionalReturnDelay
		elseif self.run == R.ExtrudeReturn or self.run == R.Resetting then
			settle(self, "Empty")
		elseif self.run == R.Objective then
			tracking(self):HandleCubeObjectiveEvent(self, self.isBoilerPedestal, self.isBoilerWaterPedestal, not self.removing, not self.by_player)
			if self.removing then
				if self.by_player then tracking(self):GiveACube(true) end
				self:UndoAction(1)
			else
				self:DoAction(1)
			end
			self.run = R.Acting
		elseif self.run == R.Acting then
			if boiler_busy(self) then return end
			self:PlayFX()
			self.run = R.Effects
		elseif self.run == R.Effects then
			if self.fx ~= F.Idle then return end
			if self.removing then self:UndoAction(2) else self:DoAction(2) end
			self.run = R.Returning
			self.run_t = self.AdditionalReturnDelay
		elseif self.run == R.Returning then
			self.failsafeDontSubmerge = not self.removing
			self:CheckSubmerged()
			settle(self, self.removing and "Empty" or "Filled")
		end
	end

	function Busy:OnTick()
		fx_tick(self)
		run_tick(self)
	end

	function Empty:OnActivate(akActivator)
		local p = player()
		if self.SuppressActivation then
			-- aqueduct bridges: only the puzzle controller activates them
			if rt.cast(akActivator, "Actor") then return end
			if p:GetItemCount(self.DLC2dunNchardakCube) <= 0 then return self.FailureMessageNoCube:Show() end
			self.asked_by = akActivator
			return self:InsertCubePlayer()
		end
		if akActivator ~= p then return end
		if akActivator:GetItemCount(self.DLC2dunNchardakCube) <= 0 then return self.FailureMessageNoCube:Show() end
		self:InsertCubePlayer()
	end

	function Filled:OnActivate(akActivator)
		if akActivator == player() then self:RemoveCubePlayer() end
	end

	function C:OnLoad()
		if not self.initialized then
			self.initialized = true
			if self.StartsFilled then
				self:RegisterForAnimationEvent(self, "Left")
				self:PlayAnimation("Forward")
			end
		elseif not self.shouldExtrude then
			if self:GetState() == "Empty" then
				self:PlayAnimation("Backward")
			elseif self:GetState() == "Filled" then
				self:PlayAnimation("Forward")
			end
		end
	end

	-- the starts-filled pedestal settles when its opening move ends
	function C:OnAnimationEvent(akSource, asEventName)
		if akSource == self and asEventName == "Left" and self.StartsFilled and self:GetState() ~= "Filled" and self.run == R.Idle then
			self:GotoState("Filled")
		end
	end
end
