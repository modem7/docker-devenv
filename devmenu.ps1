#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$GitUser = 'modem7'
$GitRepo = 'docker-devenv'
$GitFolder = 'Environments'
$BuilderName = 'DockerDevBuilder'
$Registry = "ghcr.io/$GitUser"

function Get-EnvSlug {
    param([Parameter(Mandatory)][string]$Name)
    $Name.ToLowerInvariant() -replace '_', '-'
}

function Get-ExtraPackage {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $lines = Get-Content -LiteralPath $Path | ForEach-Object { ($_ -replace '#.*', '').Trim() }
    ($lines | Where-Object { $_ -ne '' }) -join ' '
}

function Test-ExternalImage {
    param([Parameter(Mandatory)][string]$Name)
    Test-Path -LiteralPath (Join-Path $GitFolder $Name 'external-image.txt') -PathType Leaf
}

function Resolve-ImageRef {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Slug)
    if (Test-ExternalImage -Name $Name) {
        (Get-Content -LiteralPath (Join-Path $GitFolder $Name 'external-image.txt') -Raw).Trim()
    } else {
        "${Registry}/${GitRepo}-${Slug}:latest"
    }
}

function Test-Dependency {
    Write-Host "`n========================================="
    Write-Host "Checking dependencies..."
    $missing = @()
    foreach ($cmd in 'docker', 'jq', 'fzf') {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) {
            Write-Host "~ $cmd is...installed" -ForegroundColor Green
        } else {
            Write-Host "~ $cmd is...not installed" -ForegroundColor Red
            $missing += $cmd
        }
    }
    if ($missing.Count -gt 0) {
        Write-Host "Install the missing dependencies:"
        foreach ($cmd in $missing) {
            switch ($cmd) {
                'docker' { Write-Host "  docker: https://docs.docker.com/desktop/install/windows-install/" }
                'jq'     { Write-Host "  jq:  winget install jqlang.jq   (or: choco install jq)" }
                'fzf'    { Write-Host "  fzf: winget install fzf         (or: choco install fzf)" }
            }
        }
        exit 1
    }
}

function Test-RepoRoot {
    if (-not (Test-Path -LiteralPath $GitFolder -PathType Container)) {
        Write-Host "This script must be run from inside a clone of the repo." -ForegroundColor Red
        Write-Host "Run: git clone https://github.com/$GitUser/$GitRepo.git; cd $GitRepo; .\devmenu.ps1"
        exit 1
    }
}

function Get-Environment {
    Get-ChildItem -LiteralPath $GitFolder -Directory | Sort-Object Name | Select-Object -ExpandProperty Name
}

function Select-Environment {
    if ($env:DEVMENU_ENV) { return $env:DEVMENU_ENV }
    $options = @(Get-Environment) + @('Prune', 'Quit')
    $options | fzf --prompt="Choose Option: " --height=15 --border
}

function Select-Action {
    if ($env:DEVMENU_ACTION) { return $env:DEVMENU_ACTION }
    @('pull', 'build') | fzf --prompt="Pull prebuilt or build locally? " --height=8 --border `
        --header="pull = fast, prebuilt image | build = local Dockerfile + customization"
}

function Resolve-Workspace {
    param([Parameter(Mandatory)][string]$Slug)
    $default = ".\workspace\$Slug"
    if ($env:DEVMENU_WORKSPACE) {
        $workspace = $env:DEVMENU_WORKSPACE
    } else {
        $typed = Read-Host "Workspace directory to mount at /workspace [$default]"
        $workspace = if ([string]::IsNullOrWhiteSpace($typed)) { $default } else { $typed }
    }
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    (Resolve-Path -LiteralPath $workspace).Path
}

# Sets $script:ResolvedImage as an out-parameter rather than returning via
# the normal output stream: native commands like `docker pull` write their
# own progress to the success stream too, and capturing this function's
# output with `$image = Invoke-Pull ...` would silently turn $image into an
# array containing that progress output plus the real image reference.
function Invoke-Pull {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Slug)
    $image = Resolve-ImageRef -Name $Name -Slug $Slug
    Write-Host "`nPulling $image..."
    docker pull $image
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Pull failed. The image may not be published yet, or you're offline." -ForegroundColor Red
        if (-not (Test-ExternalImage -Name $Name)) {
            Write-Host "Try again and choose the 'build' option instead."
        }
        exit 1
    }
    $script:ResolvedImage = $image
}

# Sets $script:ResolvedImage as an out-parameter (see Invoke-Pull above -
# same reasoning applies to `docker buildx build`'s progress output).
function Invoke-Build {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Slug)
    $context = Join-Path $GitFolder $Name
    $extraPackages = Get-ExtraPackage -Path (Join-Path $context 'requirements.local.txt')

    Write-Host "`nCreating buildx builder..."
    docker buildx create --use --name $BuilderName *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Builder already exists, using $BuilderName..."
        docker buildx use $BuilderName
    }

    Write-Host "Building $Name..."
    docker buildx build --rm=true --build-arg BUILDKIT_INLINE_CACHE=1 `
        --build-arg "EXTRA_PACKAGES=$extraPackages" `
        --load -t "${Slug}:dev" $context
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Build failed." -ForegroundColor Red
        exit 1
    }
    $script:ResolvedImage = "${Slug}:dev"
}

function Invoke-RunContainer {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Image, [Parameter(Mandatory)][string]$Workspace)
    $containerName = "${Name}Dev$(Get-Random)"
    Write-Host "`n========================================="
    Write-Host "Activating $Name Dev Environment..."
    if ($env:DEVMENU_CMD) {
        docker run --rm -v "${Workspace}:/workspace" -w /workspace --name $containerName --hostname $containerName $Image bash -lc "$env:DEVMENU_CMD"
    } else {
        Write-Host "Press CTRL + D or type exit to leave the container."
        docker run --rm -it -v "${Workspace}:/workspace" -w /workspace --name $containerName --hostname $containerName $Image
    }
}

function Invoke-Prune {
    Write-Host "`nClearing Docker cache..."
    docker system prune -af
    Write-Host "Removing Docker buildx builder..."
    docker buildx rm $BuilderName *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Builder $BuilderName removed."
    } else {
        Write-Host "Builder already removed, no action performed."
    }
}

function Main {
    Test-Dependency
    Test-RepoRoot

    Write-Host @'
      ____             _
     |  _ \  ___   ___| | _____ _ __
     | | | |/ _ \ / __| |/ / _ | `__|
     | |_| | (_) | (__|   |  __| |
     |____/ \___/ \___|_|\_\___|_|
=========================================
'@

    $name = Select-Environment
    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Host "No selection made. Exiting."
        return
    }

    switch ($name) {
        'Prune' { Invoke-Prune; return }
        'Quit'  { Write-Host "Exiting script..."; return }
    }

    $slug = Get-EnvSlug -Name $name

    if (Test-ExternalImage -Name $name) {
        $action = 'pull'
    } else {
        $action = Select-Action
        if ([string]::IsNullOrWhiteSpace($action)) {
            Write-Host "No action selected. Exiting."
            return
        }
    }

    if ($action -eq 'pull') {
        Invoke-Pull -Name $name -Slug $slug
    } else {
        Invoke-Build -Name $name -Slug $slug
    }
    $image = $script:ResolvedImage

    $workspace = Resolve-Workspace -Slug $slug
    Invoke-RunContainer -Name $name -Image $image -Workspace $workspace
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
