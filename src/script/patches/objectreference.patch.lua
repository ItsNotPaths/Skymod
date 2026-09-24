-- pex: deletewhenable 66251d2c
-- DeleteWhenAble polled the parent cell every 5 s until it detached. It is an engine fact now: the
-- native deletes at once, or when the ref's cell detaches (script-api.md section 5).
return function(C)
	C.__fn.deletewhenable = nil
	C.__cache = {}
end
