$ErrorActionPreference = "Stop"

$repoRoot = $PSScriptRoot
$demoBinary = Join-Path ([System.IO.Path]::GetTempPath()) ("reify-validation-" + [guid]::NewGuid().ToString() + ".exe")
Push-Location $repoRoot
try {
	& odin build demo "-out:$demoBinary" -define:Reify_Enable_Validation=true
	if ($LASTEXITCODE -ne 0) {
		throw "odin build demo failed."
	}

	$hadLayers = Test-Path Env:VK_INSTANCE_LAYERS
	$previousLayers = $env:VK_INSTANCE_LAYERS
	$env:VK_INSTANCE_LAYERS = "VK_LAYER_KHRONOS_validation"
	try {
		& $demoBinary
	} finally {
		if ($hadLayers) {
			$env:VK_INSTANCE_LAYERS = $previousLayers
		} else {
			Remove-Item Env:VK_INSTANCE_LAYERS -ErrorAction SilentlyContinue
		}
	}
} finally {
	Remove-Item $demoBinary -ErrorAction SilentlyContinue
	Pop-Location
}
