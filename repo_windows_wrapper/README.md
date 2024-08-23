Various CV jobs use the Gerrit Repo plugin for syncing, however this expects
to find a repo.exe on Windows and our existing build is not compatible with
Windows Server 2022.

This app provides a binary which will run "python repo.py [args]" to act as a
drop-in replacement for the previous repo binary.
