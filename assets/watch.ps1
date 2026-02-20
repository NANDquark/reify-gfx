$ErrorActionPreference = "Stop"

Push-Location $PSScriptRoot
try {
	& watchexec -w "." -e ".slang" -w "..\tools\shader_types_gen" -e ".odin" -- `
		powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Sleep -Seconds 1; & '.\shader_compile.ps1'"
} finally {
	Pop-Location
}
