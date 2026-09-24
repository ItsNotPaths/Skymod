-- pex: firetrap 5f326919
-- pex: onload 6b491190
-- fireTrap wound up for initialDelay, then fired while shots were left: all three at once (until
-- FTransAll) or one bolt at a time (until FTrans0N, then its reset animation until RTrans0N),
-- once per Loop pass. OnLoad restarted a firing trap and set the pose for the shots left. Now
-- `run` is the step, the events end each animation, and `await` / `after_anim` name the event awaited
-- and the reset that follows it. TrapBase's trigger states change during a run, so OnTick is on
-- the class.
local rt = require('skymod.rt')

return function(C)
	C.Run = rt.sequence("Idle", "Windup", "Firing", "Resetting")
	local R = C.Run
	C.__vars.run = R.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.await = rt.string("")
	C.__vars.after_anim = rt.string("") -- the reset animation after this bolt, "" when none
	C.__vars.after_event = rt.string("")
	C.__vars.TickRate = rt.float(0.05)
	local converted_unload = C.__fn.onunload

	-- what each shot count fires: animation, weapon, end event, reset animation, reset event
	local SHOTS = {
		[3] = { "Trigger01", "ballistaWeaponM", "FTrans01", "Reset01", "RTrans01" },
		[2] = { "Trigger02", "ballistaWeaponL", "FTrans02", "Reset02", "RTrans02" },
		[1] = { "Trigger03", "ballistaWeaponR", "FTrans03", "", "" },
	}

	local function finish(self)
		self.run = R.Idle
		if not self.isLoaded then return end -- isFiring stays set: OnLoad fires again
		self.isFiring = false
		self:GotoState("Reset")
	end

	local function await(self, evt)
		self.run = R.Firing
		self.await = evt
		self:RegisterForAnimationEvent(self, evt)
	end

	-- one pass of `while (shotcount > 0) && !shotfired && isLoaded`
	local volley
	local function end_pass(self)
		self.shotFired = true
		if self.loop then self:ResetLimiter() end
		volley(self)
	end

	volley = function(self)
		if self.shotCount <= 0 or self.shotFired or not self.isLoaded then return finish(self) end
		if self.fireAllShots then
			self:PlayAnimation("TriggerAll")
			for _, w in ipairs({ "ballistaWeaponM", "ballistaWeaponL", "ballistaWeaponR" }) do self[w]:Fire(self, self.ballistaAmmo) end
			self.shotCount = self.shotCount - 3
			self.after_anim = ""
			return await(self, "FTransAll")
		end
		local s = SHOTS[self.shotCount]
		if not s then return end_pass(self) end -- Papyrus fired nothing on other counts
		self:PlayAnimation(s[0])
		self[s[1]]:Fire(self, self.ballistaAmmo)
		self.shotCount = self.shotCount - 1
		self.after_anim = s[3]
		self.after_event = s[4]
		await(self, s[2])
	end

	function C:fireTrap()
		if self.trapDisarmed or self.run ~= R.Idle then return end -- a run happens once
		self.isFiring = true
		if not self.weaponResolved then self:ResolveLeveledWeapon() end
		self.WindupSound:Play(self)
		self.run = R.Windup
		self.t = self.initialDelay
		self:OnTick()
	end

	function C:OnTick()
		if self.run ~= R.Windup or self.t > 0 then return end
		volley(self)
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= self.await then return end
		if self.run == R.Firing and self.after_anim ~= "" then
			self.run = R.Resetting
			self.await = self.after_event
			self:RegisterForAnimationEvent(self, self.await)
			self:PlayAnimation(self.after_anim)
		elseif self.run == R.Firing or self.run == R.Resetting then
			end_pass(self)
		end
	end

	-- OnLoad's pose animation for the shots left ended the event with nothing after it
	local POSE = { [3] = "Reset03", [2] = "Reset01", [1] = "Reset02" }
	function C:OnLoad()
		self.isLoaded = true
		if self.isFiring then return self:fireTrap() end -- the run sets the pose itself
		if POSE[self.shotCount] then self:PlayAnimation(POSE[self.shotCount]) end
	end

	-- an unloaded ballista sends no animation event: the run ends, isFiring stays for OnLoad
	function C:OnUnload()
		converted_unload(self)
		if self.run ~= R.Idle and self.run ~= R.Windup then self.run = R.Idle end
	end
end
