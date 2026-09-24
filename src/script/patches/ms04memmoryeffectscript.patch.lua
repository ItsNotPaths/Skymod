-- pex: fadein ae9c1a2e
-- pex: fadeout dae777df
-- FadeIn enabled the ghost and showed it 0.1 s later; FadeOut hid it and disabled it 0.1 s later.
-- Each now starts a fade that OnTick ends. The state (FadingIn, FadingOut) is the published fact.
local rt = require('skymod.rt')

return function(C)
	C.__vars.wantShown = rt.bool(false) -- a request during a fade is settled when it ends
	C.__vars.fadeT = rt.timer(0.0)
	local split_tick = C.__fn.ontick

	local function fading(self)
		local s = self:GetState()
		return s == "FadingIn" or s == "FadingOut"
	end

	local function start(self)
		if self.wantShown then
			self:GotoState("FadingIn")
			self:Enable()
		else
			self:GotoState("FadingOut")
			self.MS04MemoryFXBody01VFX:Stop(self)
			self:SetAlpha(0.0, true)
		end
		self.fadeT = 0.1
	end

	function C:FadeIn()
		self.wantShown = true
		if not fading(self) then start(self) end
	end

	function C:FadeOut()
		self.wantShown = false
		if not fading(self) then start(self) end
	end

	function C:OnTick()
		split_tick(self)
		if not fading(self) or self.fadeT > 0 then return end
		local shown = self:GetState() == "FadingIn"
		self:GotoState("")
		if shown then
			self:SetAlpha(self.GhostAlpha, true)
			self.MS04MemoryFXBody01VFX:Play(self)
		else
			self:Disable()
		end
		if self.wantShown ~= shown then start(self) end
	end
end
