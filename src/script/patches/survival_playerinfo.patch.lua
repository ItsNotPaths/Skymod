-- pex: enteroblivion ccc1410e
-- pex: exitoblivion bcdea391
-- pex: onupdate 74e36a59
-- No change: they waited only inside each need's SetInOblivion, which now owes the change to the
-- need and returns (Survival_NeedBase). Nothing after the calls reads what the needs do.
return function(C) end
