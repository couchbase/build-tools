package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"time"
)

// Tool name is templated in at build time
const toolName = "__TOOL_NAME__"

func main() {

	// Set the path to the tool and uv
	shimDir := fmt.Sprintf("%s\\.local\\shims", os.Getenv("USERPROFILE"))
	toolPath := fmt.Sprintf("%s\\%s.exe", shimDir, toolName)
	uv := fmt.Sprintf("%s\\.local\\bin\\uv.exe", os.Getenv("USERPROFILE"))

	installTool := func() {
		// Ensure install directory exists
		err := os.MkdirAll(shimDir, 0755)
		if err != nil {
			panic(err)
		}

		cmd := exec.Command(uv, "tool", "install", "--reinstall", "--python-preference=only-managed", toolName)
		// UV_TOOL_BIN_DIR controls where the shim goes
		cmd.Env = append(os.Environ(), fmt.Sprintf("UV_TOOL_BIN_DIR=%s", shimDir))
		var stdout, stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr

		err = cmd.Run()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error installing %s:\n", toolName)
			fmt.Fprintf(os.Stderr, "Stdout: %s\n", stdout.String())
			fmt.Fprintf(os.Stderr, "Stderr: %s\n", stderr.String())
			panic(err)
		}
	}

	// Check if tool exists
	if toolInfo, err := os.Stat(toolPath); os.IsNotExist(err) {

		// Check if uv exists
		if _, err = os.Stat(uv); os.IsNotExist(err) {
			// Need to unset PSMODULEPATH to ensure the right Powershell
			// standard library is used.
			// https://github.com/PowerShell/PowerShell/issues/18530#issuecomment-1325691850
			os.Unsetenv("PSMODULEPATH")
			cmd := exec.Command("powershell", "-ExecutionPolicy", "Bypass",
				"-Command", "[Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; irm https://astral.sh/uv/install.ps1 | iex")
			var stdout, stderr bytes.Buffer
			cmd.Stdout = &stdout
			cmd.Stderr = &stderr

			err = cmd.Run()
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error installing uv:\n")
				fmt.Fprintf(os.Stderr, "Stdout: %s\n", stdout.String())
				fmt.Fprintf(os.Stderr, "Stderr: %s\n", stderr.String())
				panic(err)
			}
		}

		installTool()

	} else {

		// If tool exists, check if it's older than 48 hours
		cutoff := time.Now().Add(-48 * time.Hour)
		if toolInfo.ModTime().Before(cutoff) {
			// If it's old, delete it and re-install - don't just re-install
			// because that doesn't actually change the modification time of
			// this uv-provided tool.exe
			err := os.Remove(toolPath)
			if err != nil {
				panic(err)
			}

			installTool()
		}
	}

	// Run tool, passing all of our arguments
	cmd := exec.Command(toolPath, os.Args[1:]...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	err := cmd.Run()
	if err != nil {
		// panic unless the error is just that the command exited with a
		// non-zero status
		exitErr, isExitError := err.(*exec.ExitError)
		if isExitError {
			os.Exit(exitErr.ExitCode())
		} else {
			panic(err)
		}
	}
}
