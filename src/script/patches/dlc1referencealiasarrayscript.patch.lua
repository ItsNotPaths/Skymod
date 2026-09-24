-- pex: clearreffrom 89a65a5a
-- pex: forcerefinto 7b979f17
-- pex: lockthread fc43099a
-- LockThread waited while threadLock was set. ForceRefInto and ClearRefFrom, its only callers, set
-- and clear it with no wait between, so no call ever sees it set: the wait loop is gone, and the
-- two callers need no change.
return function(C)
	function C:LockThread()
		self.threadLock = true
	end
end
