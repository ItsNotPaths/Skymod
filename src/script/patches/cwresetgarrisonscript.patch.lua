-- pex: startcwgovernmentquestifcapital c2200aef
-- StartCWGovernmentQuestIfCapital sent CWGovernmentStart and then polled every 1 s until
-- CWGovernmentScript cleared WaitingForCallBackFromCWGovernment. It now sends and returns; the flag
-- is the published fact, and the stage 0 fragment waits on it.
local rt = require('skymod.rt')

return function(C)
	function C:StartCWGovernmentQuestIfCapital()
		if self.WaitingForCallBackFromCWGovernment then return end
		local garrisonLoc = self.Garrison:GetLocation()
		if not garrisonLoc:HasKeyword(self.CWs.CWCapital) then return end
		self.WaitingForCallBackFromCWGovernment = true
		self.CWs.CWGovernmentStart:SendStoryEvent(garrisonLoc)
	end
end
