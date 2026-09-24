-- pex: startmyscene a01ddc1f
-- StartMyScene started the scene, then (if WaitUntilSceneCompletes) polled Scene.IsPlaying with
-- no effect once the poll ended. Every caller is free (script-api.md section 6), so the wait had
-- no observable outcome; starting the scene is the whole behaviour.
local rt = require('skymod.rt')

return function(C)
	rt.params(C, "StartMyScene", { { "WaitUntilSceneCompletes", false }, { "waitTimeMax", 600 } })

	function C:StartMyScene(WaitUntilSceneCompletes, waitTimeMax)
		self.myScene:Start()
	end
end
