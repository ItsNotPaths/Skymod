-- pex: clearreffrom e0b3a444
-- pex: forcerefinto 074d9a14
-- pex: forcereftoandreturnalias 39d19d6c
-- pex: lockthread fc43099a
-- LockThread waited while threadLock was set. ClearRefFrom and ForceRefToAndReturnAlias set and
-- clear it with no wait between (DoIfFull's only override, DLC2ExpSpiderAliasArrayScript, calls the
-- control script's SpiderCrumble, which never waits), so no call sees it set. The loop is gone; the
-- other functions need no change.
return function(C)
	function C:LockThread()
		self.threadLock = true
	end
end
