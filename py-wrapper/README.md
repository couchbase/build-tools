Simple Windows C program to generate an .exe that invokes a Python script.

Sometimes when invoking a program on Windows, such as execing from Python,
Windows will ONLY look for a .exe of the given name. This is a problem
when you want to invoke a Python script using a local Python interpreter.

This program is a simple work-around. If you build it with the name
"my-py-program", it will produce a "my-py-program.exe" that will simply
invoke "python2 \path\to\my-py-program", passing in any command-line
arguments. It presumes that my-py-program exists in the same directory
as my-py-program.exe.

To build, first run the "vcvarsall.bat" script for your version of Visual
Studio to put cl.exe on the PATH. Then:

   mkdir build
   cd build
   cmake -G Ninja -D CMAKE_C_COMPILER=cl -D PYSCRIPT=my-py-program ..
   ninja

(This works equally well with MinGW; just set up MinGW on your PATH and
skip the -D CMAKE_C_COMPILER argument.)

This program was used to create the "repo.exe" which is on the newest
Windows build agents. The "repo" Python script itself came from
https://raw.githubusercontent.com/esrlabs/git-repo/stable/repo and is based
on https://github.com/esrlabs/git-repo, a port of Repo to Windows.
