param([string]$Revision = '87abe23')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$paths = @('scenes/game_world.tscn', 'scripts/render/day_cycle.gd')
$paths += git -C $projectRoot ls-tree -r --name-only $Revision resources |
    Where-Object { $_ -match '\.gdshader(inc)?$' }
foreach ($relative in $paths) {
    $source = git -C $projectRoot show "${Revision}:$relative"
    if ($LASTEXITCODE -ne 0) { throw "Cannot read $relative at $Revision" }
    $content = ($source -join "`n").Replace('res://resources/', 'res://.godot/lighting_baseline/resources/')
    $destination = Join-Path $projectRoot ".godot/lighting_baseline/$relative"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    [IO.File]::WriteAllText($destination, $content, [Text.UTF8Encoding]::new($false))
}
Write-Output "Lighting baseline prepared from $Revision; working sources unchanged."
