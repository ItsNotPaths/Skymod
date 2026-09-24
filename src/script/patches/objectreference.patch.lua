-- pex: deletewhenable 66251d2c
-- pex: movetowhenunloaded 6b5b977c
-- DeleteWhenAble and MoveToWhenUnloaded polled every 5 s until a cell or both locations unloaded.
-- They are engine facts now: the natives act at once, or when a cell detaches (script-api.md section 5).
return function(C)
	C.__fn.deletewhenable = nil
	C.__fn.movetowhenunloaded = nil
	C.__cache = {}
end
