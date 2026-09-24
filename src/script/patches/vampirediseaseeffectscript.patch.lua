-- pex: onupdategametime ae6aa902
-- At 5:00 and 19:00 the disease showed its message and faded the screen in for 2 s before
-- removing the fade; then it checked whether the change was due. Now OnTick in Fading holds
-- the 2 s and does the check after, as before.
-- HOLE(magic, gap): runs on an effect instance, which nothing makes yet.
local rt = require('skymod.rt')

return function(C)
	C.__vars.fade_t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Fading = rt.state(C, "Fading")

	local function check_change(self)
		if self.GameDaysPassed:GetValue() >= self.VampireChangeTimer then
			self:UnregisterForUpdateGameTime()
			self:RegisterForSingleUpdate(10)
		end
	end

	function C:OnUpdateGameTime()
		if self:GetState() == "Fading" then return end
		local hour = self.GameHour:GetValueInt()
		if hour == 5 or hour == 19 then
			if hour == 5 then
				self.VampireSunriseMessage:Show()
				self.VampireTransformDecreaseISMD:ApplyCrossFade(2.0)
			else
				self.VampireSunsetMessage:Show()
				self.VampireTransformIncreaseISMD:ApplyCrossFade(2.0)
			end
			self.fade_t = 2.0
			return self:GotoState("Fading")
		end
		check_change(self)
	end

	function Fading:OnTick()
		if self.fade_t > 0 then return end
		rt.static("ImageSpaceModifier", "RemoveCrossFade")
		self:GotoState("")
		check_change(self)
	end
end
