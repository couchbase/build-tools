#include <stdio.h>
#include <stdlib.h>
#include <process.h>
#include <windows.h>
#include <libloaderapi.h>

int main(int argc, char** argv) {
  char scriptFile[_MAX_FNAME];
  char* cp;

  /* Path to current executable */
  GetModuleFileName(NULL, scriptFile, sizeof(scriptFile));

  /* Strip the extension */
  cp = strrchr(scriptFile, '.');
  *cp = '\0';

  /* Get current full command-line, and jump past argv[0] */
  char* cmdLine = GetCommandLine();
  char *s = cmdLine;
  if (*s == '"') {
    ++s;
    while (*s)
      if (*s++ == '"')
        break;
  } else {
    while (*s && *s != ' ' && *s != '\t')
      ++s;
  }
  cmdLine = s;

  /* Form final command line, with all the requisite quotes and spaces */
  char pyCmdLine[32768];
  sprintf(pyCmdLine, "\"python2\" \"%s\" %s", scriptFile, cmdLine);

  /* Exec real python */
  STARTUPINFO si;
  PROCESS_INFORMATION pi;
  ZeroMemory(&si, sizeof(si));
  si.cb = sizeof(si);
  ZeroMemory(&pi, sizeof(pi));

  if( !CreateProcess( NULL,   // No module name (use command line)
      pyCmdLine,      // Command line
      NULL,           // Process handle not inheritable
      NULL,           // Thread handle not inheritable
      FALSE,          // Set handle inheritance to FALSE
      0,              // No creation flags
      NULL,           // Use parent's environment block
      NULL,           // Use parent's starting directory
      &si,            // Pointer to STARTUPINFO structure
      &pi )           // Pointer to PROCESS_INFORMATION structure
  ) {
    printf("CreateProcess failed (%d).\n", GetLastError());
    exit(1);
  }

  /* Wait until child process exits */
  DWORD exitCode;
  WaitForSingleObject(pi.hProcess, INFINITE);
  GetExitCodeProcess(pi.hProcess, &exitCode);

  /* Close process and thread handles */
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);

  exit(exitCode);
}
