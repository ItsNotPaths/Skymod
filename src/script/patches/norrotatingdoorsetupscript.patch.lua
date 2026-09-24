-- pex: onload 3e138fce
-- OnLoad: normalize desiredAngle (the original recursed through OnLoad), start the rotation, and
-- stop it after |angle| / 15 s (integer division, as in Papyrus).
local rt = require('skymod.rt')

local function trace(self, msg)
	rt.static("Debug", "Trace", "NorRotatingDoorSetup " .. tostring(self.form) .. ": " .. msg)
end

return function(C)
	C.__vars.rotateLeft = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Rotating = rt.state(C, "Rotating")

	function C:OnLoad()
		-- same arithmetic as the original, including 180 - a for a > 180
		while self.desiredAngle > 180 or self.desiredAngle < -180 do
			if self.desiredAngle > 180 then
				self.desiredAngle = 180 - self.desiredAngle
			else
				self.desiredAngle = 360 + self.desiredAngle
			end
		end
		if self:GetState() == "Rotating" then
			trace(self, "OnLoad dropped: still rotating (angle now " .. self.desiredAngle .. ")")
			return
		end
		local angle = self.desiredAngle
		if angle > 0 then
			self:PlayAnimation("rotateLeft")
		else
			self:PlayAnimation("rotateRight")
			angle = -angle
		end
		self.rotateLeft = rt.cast(rt.idiv(angle, 15), "float")
		self:GotoState("Rotating")
		trace(self, "rotating to " .. self.desiredAngle .. " for " .. self.rotateLeft .. " s")
	end

	function Rotating:OnTick()
		if self.rotateLeft > 0 then return end
		self:GotoState("")
		self:PlayAnimation("Stop")
		trace(self, "stopped")
	end
end
