-- pex: processhitevent 64bbd0ad
-- pex: waitandshake 33a72087
-- ProcessHitEvent played the hit side's animation, called waitAndShake (a fixed 2 s shake), then
-- enabled the next trigger and advanced that side's state; the final trigger shook twice more
-- (1.2 s apart) before finishing. `pendingHit` names which side is mid-shake, a fact ProcessHitEvent
-- itself sets before the wait. waitAndShake stays a real callable with its own guard, unrelated to
-- the dispatch (ProcessHitEvent does its own shake so a caller of either sees the right wait).
local rt = require('skymod.rt')

local Hit = rt.sequence("Idle", "Shaking", "Finalizing1", "Finalizing2")
local Shake = rt.sequence("Idle", "Waiting")

return function(C)
	C.__vars.hit = Hit.Idle
	C.__vars.hitT = rt.timer(0.0)
	C.__vars.pendingHit = rt.form("ObjectReference")
	C.__vars.shake = Shake.Idle
	C.__vars.shakeT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)

	function C:waitAndShake()
		if self.shake ~= Shake.Idle then return end -- a run happens once
		rt.static("Game", "ShakeCamera", rt.None, 0.5, 0)
		rt.static("Game", "ShakeController", 0.4, 0.4, 2.0)
		self.shake, self.shakeT = Shake.Waiting, 2.0
	end

	local Waiting = rt.state(C, "waiting")
	function Waiting:ProcessHitEvent(hitRef)
		if self.hit ~= Hit.Idle then return end -- a run happens once
		local right, left = self.dlc2bloodskaldoorrightref, self.dlc2bloodskaldoorleftref
		if hitRef == self.dlc2bloodskaldoorhittriggerr001 then
			right:PlayAnimation("Play01")
		elseif hitRef == self.dlc2bloodskaldoorhittriggerr002 then
			right:PlayAnimation("Play02")
		elseif hitRef == self.dlc2bloodskaldoorhittriggerr003 then
			right:PlayAnimation("Play03")
		elseif hitRef == self.dlc2bloodskaldoorhittriggerl001 then
			left:PlayAnimation("Play01")
		elseif hitRef == self.dlc2bloodskaldoorhittriggerl002 then
			left:PlayAnimation("Play02")
		elseif hitRef == self.dlc2bloodskaldoorhittriggerl003 then
			left:PlayAnimation("Play03")
		elseif hitRef == self.dlc2bloodskaldoorhittriggerfinal then
			self:GotoState("done")
			self.qstgreybeardrumble:Play(right)
			rt.static("Game", "ShakeCamera", rt.None, 1.0, 0.0)
			rt.static("Game", "ShakeController", self.controllershakel, self.controllershaker, self.controllershakeduration)
			self.pendingHit, self.hit, self.hitT = hitRef, Hit.Finalizing1, 1.2
			return
		else
			return
		end
		rt.static("Game", "ShakeCamera", rt.None, 0.5, 0)
		rt.static("Game", "ShakeController", 0.4, 0.4, 2.0)
		self.pendingHit, self.hit, self.hitT = hitRef, Hit.Shaking, 2.0
	end

	function C:OnTick()
		if self.shake == Shake.Waiting and self.shakeT <= 0 then self.shake = Shake.Idle end
		if self.hitT > 0 then return end
		if self.hit == Hit.Shaking then
			local hitRef = self.pendingHit
			if hitRef == self.dlc2bloodskaldoorhittriggerr001 then
				self.dlc2bloodskaldoorhittriggerr002:Enable()
				self.rightsidestate = 1
			elseif hitRef == self.dlc2bloodskaldoorhittriggerr002 then
				self.dlc2bloodskaldoorhittriggerr003:Enable()
				self.rightsidestate = 2
			elseif hitRef == self.dlc2bloodskaldoorhittriggerr003 then
				self.rightsidestate = 3
				if self.rightsidestate == 3 and self.leftsidestate == 3 then
					self.dlc2bloodskaldoorrightref:PlayAnimation("Play04")
					self.dlc2bloodskaldoorhittriggerfinal:Enable()
				end
			elseif hitRef == self.dlc2bloodskaldoorhittriggerl001 then
				self.dlc2bloodskaldoorhittriggerl002:Enable()
				self.leftsidestate = 1
			elseif hitRef == self.dlc2bloodskaldoorhittriggerl002 then
				self.dlc2bloodskaldoorhittriggerl003:Enable()
				self.leftsidestate = 2
			elseif hitRef == self.dlc2bloodskaldoorhittriggerl003 then
				self.leftsidestate = 3
				if self.rightsidestate == 3 and self.leftsidestate == 3 then
					self.dlc2bloodskaldoorrightref:PlayAnimation("Play04")
					self.dlc2bloodskaldoorhittriggerfinal:Enable()
				end
			end
			self.hit, self.pendingHit = Hit.Idle, rt.None
		elseif self.hit == Hit.Finalizing1 then
			rt.static("Game", "ShakeCamera", rt.None, 1.0, 0.0)
			self.dlc2bloodskaldoorrightref:PlayAnimation("Play05")
			self.hit, self.hitT = Hit.Finalizing2, 1.2
		elseif self.hit == Hit.Finalizing2 then
			rt.static("Game", "ShakeCamera", rt.None, 1.0, 0.0)
			self.hit = Hit.Idle
		end
	end
end
