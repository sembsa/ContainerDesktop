-- Accessibility bridge for the screenshot workflow (scripts/screenshots.sh).
--
-- macOS grants "Accessibility" per application, and a terminal only picks up a
-- freshly granted permission after it restarts — impractical mid-session. So the
-- screenshot script compiles this file into a small .app (osacompile) and drives
-- the UI through that instead: the .app gets its own Accessibility entry, which
-- takes effect immediately because every run is a fresh launch.
--
-- Protocol (no launch arguments — applets do not receive `open --args` reliably):
--   caller writes  ~/.container-desktop-shots/step.applescript
--   caller runs    open -a ContainerDesktopShots.app
--   applet writes  ~/.container-desktop-shots/result.txt  ("OK\n<result>" or "ERR <n>\n<msg>")
--
-- File IO goes through `do shell script` because AppleScript's own `write` is
-- unreliable inside an applet launched this way.

on run
	set base to (POSIX path of (path to home folder)) & ".container-desktop-shots"
	set stepFile to base & "/step.applescript"
	set resultFile to base & "/result.txt"
	try
		set src to do shell script "cat " & quoted form of stepFile
		set res to run script src
		if res is missing value then set res to "ok"
		my report(resultFile, "OK" & linefeed & (res as text))
	on error errMsg number errNum
		my report(resultFile, "ERR " & errNum & linefeed & errMsg)
	end try
end run

on report(resultFile, txt)
	do shell script "printf %s " & quoted form of txt & " > " & quoted form of resultFile
end report
