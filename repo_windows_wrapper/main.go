package main

import (
    "fmt"
    "os"
    "os/exec"
    "path/filepath"
)

func main() {
    executablePath, err := os.Executable()

    if err != nil {
        fmt.Printf("Error determining executable path: %v\n", err)
        os.Exit(1)
    }

    executableDir := filepath.Dir(executablePath)
    pythonScript := filepath.Join(executableDir, "repo")
    args := os.Args[1:]

    pythonArgs := append([]string{pythonScript}, args...)

    cmd := exec.Command("python", pythonArgs...)
    cmd.Stdout = os.Stdout
    cmd.Stderr = os.Stderr

    err = cmd.Run()

    if exitError, ok := err.(*exec.ExitError); ok {
        os.Exit(exitError.ExitCode())
    } else if err != nil {
        fmt.Printf("Error executing: %v\n", err)
        os.Exit(1)
    }

    os.Exit(0)
}
