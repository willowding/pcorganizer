#Requires -Version 5.1
<#
.SYNOPSIS
    一键把 PCOrganizer 推送到你的 GitHub 仓库。
    需要：① 安装 Git  ② 安装 GitHub CLI (gh)  ③ gh auth login 登录过
    下载：https://git-scm.com/download/win
         https://cli.github.com/
#>
param(
    [string]$RepoName  = 'pc-organizer',
    [string]$RepoDesc  = 'Windows PC 文件智能整理工具：游戏迁移到 SSD/E 盘，AI 资料归集，存档跟随，目录联接无感知',
    [ValidateSet('public','private')]
    [string]$Visibility = 'public'
)

$scriptDir = Split-Path $PSCommandPath -Parent

function Check-Command($cmd) {
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

if (-not (Check-Command 'git')) {
    Write-Host "❌ 未找到 git，请先安装 Git for Windows：https://git-scm.com/download/win" -ForegroundColor Red
    Start-Process "https://git-scm.com/download/win"
    exit 1
}

if (-not (Check-Command 'gh')) {
    Write-Host "❌ 未找到 GitHub CLI，请先安装：https://cli.github.com/" -ForegroundColor Red
    Start-Process "https://cli.github.com/"
    exit 1
}

# 检查 gh 登录状态
$loginCheck = & gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "未登录 GitHub CLI，正在打开登录流程……" -ForegroundColor Yellow
    & gh auth login
    if ($LASTEXITCODE -ne 0) { Write-Host "登录失败，请重试。" -ForegroundColor Red; exit 1 }
}

Set-Location $scriptDir

# 初始化 git（如果还没有）
if (-not (Test-Path '.git')) {
    & git init
    & git add .gitignore 2>$null
}

# 写 .gitignore（不提交 logs 里的日志文件）
$gitignore = @"
logs/inventory_*.json
logs/plan_*.json
logs/op_*.json
"@
Set-Content '.gitignore' $gitignore -Encoding UTF8

& git add -A
& git commit -m "feat: 初始提交 PCOrganizer" 2>&1 | Write-Host

# 在 GitHub 创建仓库并推送
Write-Host "`n正在 GitHub 上创建仓库 '$RepoName'……" -ForegroundColor Cyan
& gh repo create $RepoName --description $RepoDesc "--$Visibility" --source . --remote origin --push

if ($LASTEXITCODE -eq 0) {
    $url = & gh repo view --json url -q '.url' 2>$null
    Write-Host "`n推送成功！仓库地址：$url" -ForegroundColor Green

    # 开启 GitHub Pages（从 /docs 目录）
    Write-Host "`n正在开启 GitHub Pages (docs 目录)……" -ForegroundColor Cyan
    & gh api "repos/$(gh api user -q .login)/$RepoName/pages" `
        -X POST `
        -f "source[branch]=main" `
        -f "source[path]=/docs" 2>$null
    if ($LASTEXITCODE -eq 0) {
        $pagesUrl = "https://$(& gh api user -q .login).github.io/$RepoName/"
        Write-Host "GitHub Pages 已开启！" -ForegroundColor Green
        Write-Host "网站地址（约 1 分钟后生效）：$pagesUrl" -ForegroundColor Green

        # 把仓库 URL 写入 docs\index.html，替换占位符
        $htmlPath = Join-Path $scriptDir 'docs\index.html'
        if (Test-Path $htmlPath) {
            (Get-Content $htmlPath -Raw) -replace 'https://github.com/YOUR_USERNAME/pc-organizer', $url |
                Set-Content $htmlPath -Encoding UTF8
            & git add 'docs/index.html'
            & git commit -m "chore: 更新 GitHub Pages 链接"
            & git push
            Write-Host "仓库链接已自动写入网页。" -ForegroundColor Green
        }
        Start-Process $pagesUrl
    } else {
        Write-Host "Pages 开启失败（可能需要手动在 Settings → Pages 里设置 Source = docs 目录）" -ForegroundColor Yellow
    }
    Start-Process $url
} else {
    Write-Host "`n仓库可能已存在，尝试直接推送……" -ForegroundColor Yellow
    & git remote add origin "https://github.com/$(gh api user -q .login)/$RepoName.git" 2>$null
    & git branch -M main
    & git push -u origin main
}
