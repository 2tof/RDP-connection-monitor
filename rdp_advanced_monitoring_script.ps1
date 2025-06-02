# RDP连接高级性能监测与日志记录脚本
# 作者: Manus AI
# 版本: 2.0
# 描述: 此脚本用于监测RDP连接状态、延迟、带宽使用情况和UDP状态，并将结果记录到日志文件中

# 参数定义
param (
    [Parameter(HelpMessage="监测间隔（秒）")]
    [int]$MonitorInterval = 10,
    
    [Parameter(HelpMessage="日志文件路径")]
    [string]$LogFilePath = "$env:USERPROFILE\Documents\RDP_Monitoring_Logs",
    
    [Parameter(HelpMessage="是否持续监测")]
    [switch]$Continuous,
    
    [Parameter(HelpMessage="如果不是持续监测，指定监测次数")]
    [int]$SampleCount = 6,
    
    [Parameter(HelpMessage="网络接口描述（默认为以太网）")]
    [string]$NetworkInterface = "*ethernet*",
    
    [Parameter(HelpMessage="RDP服务器主机名或IP地址，用于延迟测试")]
    [string]$RDPServer = $env:COMPUTERNAME,
    
    [Parameter(HelpMessage="RDP端口")]
    [int]$RDPPort = 3389
)

# 创建日志目录（如果不存在）
if (-not (Test-Path -Path $LogFilePath)) {
    New-Item -ItemType Directory -Path $LogFilePath -Force | Out-Null
    Write-Host "已创建日志目录: $LogFilePath"
}

# 日志文件名（使用当前日期）
$Date = Get-Date -Format "yyyy-MM-dd"
$StatusLogFile = "$LogFilePath\RDP_Status_$Date.csv"
$BandwidthLogFile = "$LogFilePath\RDP_Bandwidth_$Date.csv"
$PerformanceLogFile = "$LogFilePath\RDP_Performance_$Date.csv"

# 检查日志文件是否存在，如果不存在则创建并添加标题行
if (-not (Test-Path -Path $StatusLogFile)) {
    "Timestamp,EventID,UserName,SourceIP,ConnectionStatus" | Out-File -FilePath $StatusLogFile -Encoding utf8
    Write-Host "已创建RDP状态日志文件: $StatusLogFile"
}

if (-not (Test-Path -Path $BandwidthLogFile)) {
    "Timestamp,NetworkInterface,BytesSent,BytesReceived,BytesTotal,KbpsSent,KbpsReceived,KbpsTotal" | Out-File -FilePath $BandwidthLogFile -Encoding utf8
    Write-Host "已创建RDP带宽日志文件: $BandwidthLogFile"
}

if (-not (Test-Path -Path $PerformanceLogFile)) {
    "Timestamp,Latency,UDPStatus,TCPConnections,UDPConnections" | Out-File -FilePath $PerformanceLogFile -Encoding utf8
    Write-Host "已创建RDP性能日志文件: $PerformanceLogFile"
}

# 定义网络性能计数器
$counters = @(
    "\Network Interface($NetworkInterface)\Bytes Sent/sec",
    "\Network Interface($NetworkInterface)\Bytes Received/sec",
    "\Network Interface($NetworkInterface)\Bytes Total/sec"
)

# 函数：测量网络延迟
function Measure-NetworkLatency {
    param (
        [string]$ComputerName,
        [int]$Port = 3389
    )
    
    try {
        # 方法1：使用ICMP Ping测试延迟
        $pingLatency = Test-Connection -ComputerName $ComputerName -Count 3 -ErrorAction SilentlyContinue | 
            Measure-Object -Property ResponseTime -Average | 
            Select-Object -ExpandProperty Average
        
        # 方法2：使用TCP连接测试延迟
        $tcpLatency = 0
        $successCount = 0
        
        for ($i = 0; $i -lt 3; $i++) {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            
            try {
                # 尝试连接到RDP端口
                $connectionTask = $tcpClient.ConnectAsync($ComputerName, $Port)
                
                # 等待最多2秒
                if ($connectionTask.Wait(2000)) {
                    $stopwatch.Stop()
                    
                    if ($tcpClient.Connected) {
                        $tcpLatency += $stopwatch.ElapsedMilliseconds
                        $successCount++
                    }
                }
            }
            catch {
                # 连接失败，忽略错误
            }
            finally {
                if ($tcpClient.Connected) {
                    $tcpClient.Close()
                }
            }
            
            Start-Sleep -Milliseconds 200
        }
        
        if ($successCount -gt 0) {
            $tcpLatency = $tcpLatency / $successCount
        }
        else {
            $tcpLatency = $null
        }
        
        # 综合两种方法的结果
        if ($pingLatency -and $tcpLatency) {
            return [math]::Round(($pingLatency + $tcpLatency) / 2, 2)
        }
        elseif ($pingLatency) {
            return [math]::Round($pingLatency, 2)
        }
        elseif ($tcpLatency) {
            return [math]::Round($tcpLatency, 2)
        }
        else {
            return $null
        }
    }
    catch {
        Write-Host "测量网络延迟时出错: $_" -ForegroundColor Red
        return $null
    }
}

# 函数：检测UDP状态
function Get-RDPUDPStatus {
    try {
        # 检查客户端UDP设置
        $clientUDP = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client" -Name "fClientDisableUDP" -ErrorAction SilentlyContinue
        
        # 检查服务器UDP设置
        $serverUDP = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "fDisableUDP" -ErrorAction SilentlyContinue
        
        if (($clientUDP -and $clientUDP.fClientDisableUDP -eq 1) -or ($serverUDP -and $serverUDP.fDisableUDP -eq 1)) {
            return "Disabled"
        }
        
        # 检查UDP端口3389是否开放
        $udpListener = Get-NetUDPEndpoint | Where-Object { $_.LocalPort -eq 3389 -or $_.RemotePort -eq 3389 } -ErrorAction SilentlyContinue
        
        if ($udpListener) {
            return "Active"
        }
        else {
            # 如果没有明确禁用且没有检测到活动连接
            return "Enabled_Inactive"
        }
    }
    catch {
        Write-Host "检测UDP状态时出错: $_" -ForegroundColor Red
        return "Unknown"
    }
}

# 函数：获取RDP连接状态
function Get-RDPConnectionStatus {
    try {
        # 查询RDP连接事件（登录成功）
        $loginEvents = Get-WinEvent -LogName "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational" -MaxEvents 10 -ErrorAction SilentlyContinue | 
            Where-Object {$_.ID -eq 1149}
        
        # 查询RDP断开连接事件
        $logoffEvents = Get-WinEvent -LogName "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational" -MaxEvents 10 -ErrorAction SilentlyContinue | 
            Where-Object {$_.ID -eq 24 -or $_.ID -eq 23 -or $_.ID -eq 21}
        
        # 处理登录事件
        foreach ($event in $loginEvents) {
            $timestamp = $event.TimeCreated
            $eventXml = [xml]$event.ToXml()
            $userName = $eventXml.Event.UserData.EventXML.Param1
            $sourceIP = $eventXml.Event.UserData.EventXML.Param3
            
            # 记录到日志文件
            "$timestamp,1149,$userName,$sourceIP,Connected" | Out-File -FilePath $StatusLogFile -Append -Encoding utf8
            
            # 输出到控制台
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - 用户 $userName 从 $sourceIP 连接到RDP" -ForegroundColor Green
        }
        
        # 处理断开连接事件
        foreach ($event in $logoffEvents) {
            $timestamp = $event.TimeCreated
            $eventXml = [xml]$event.ToXml()
            $userName = $eventXml.Event.UserData.EventXML.User
            $sessionID = $eventXml.Event.UserData.EventXML.SessionID
            
            # 记录到日志文件
            "$timestamp,$($event.ID),$userName,N/A,Disconnected" | Out-File -FilePath $StatusLogFile -Append -Encoding utf8
            
            # 输出到控制台
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - 用户 $userName (会话ID: $sessionID) 断开RDP连接" -ForegroundColor Yellow
        }
        
        # 获取当前活动RDP会话
        $activeSessions = query session | Where-Object { $_ -match "rdp-tcp" }
        if ($activeSessions) {
            Write-Host "当前活动RDP会话:" -ForegroundColor Cyan
            $activeSessions | ForEach-Object { Write-Host $_ }
        }
        
        # 获取TCP和UDP连接数
        $tcpConnections = Get-NetTCPConnection -LocalPort 3389 -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count
        $udpConnections = Get-NetUDPEndpoint -LocalPort 3389 -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count
        
        return @{
            TCPConnections = $tcpConnections
            UDPConnections = $udpConnections
        }
    }
    catch {
        Write-Host "获取RDP连接状态时出错: $_" -ForegroundColor Red
        return @{
            TCPConnections = 0
            UDPConnections = 0
        }
    }
}

# 函数：监测网络带宽
function Monitor-NetworkBandwidth {
    try {
        # 获取网络性能计数器数据
        $counterData = Get-Counter -Counter $counters -ErrorAction SilentlyContinue
        
        if ($counterData) {
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $networkName = $counterData.CounterSamples[0].InstanceName
            
            # 获取字节数据
            $bytesSent = $counterData.CounterSamples[0].CookedValue
            $bytesReceived = $counterData.CounterSamples[1].CookedValue
            $bytesTotal = $counterData.CounterSamples[2].CookedValue
            
            # 转换为Kbps (乘以0.008)
            $kbpsSent = [math]::Round($bytesSent * 0.008, 2)
            $kbpsReceived = [math]::Round($bytesReceived * 0.008, 2)
            $kbpsTotal = [math]::Round($bytesTotal * 0.008, 2)
            
            # 记录到日志文件
            "$timestamp,$networkName,$bytesSent,$bytesReceived,$bytesTotal,$kbpsSent,$kbpsReceived,$kbpsTotal" | 
                Out-File -FilePath $BandwidthLogFile -Append -Encoding utf8
            
            # 输出到控制台
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - 网络接口: $networkName" -ForegroundColor Cyan
            Write-Host "  发送: $kbpsSent Kbps, 接收: $kbpsReceived Kbps, 总计: $kbpsTotal Kbps" -ForegroundColor Cyan
            
            # 创建进度条显示
            $totalPct = [math]::Min(100, $kbpsTotal)
            $sentPct = [math]::Min(100, $kbpsSent)
            $rcvdPct = [math]::Min(100, $kbpsReceived)
            
            Write-Progress -Activity "[$timestamp] 网络接口: $networkName" -Status "总带宽: $kbpsTotal Kbps" -Id 1 -PercentComplete $totalPct
            Write-Progress -Activity " " -Status "发送带宽: $kbpsSent Kbps" -Id 2 -PercentComplete $sentPct
            Write-Progress -Activity " " -Status "接收带宽: $kbpsReceived Kbps" -Id 3 -PercentComplete $rcvdPct
            
            return @{
                KbpsSent = $kbpsSent
                KbpsReceived = $kbpsReceived
                KbpsTotal = $kbpsTotal
            }
        }
        
        return $null
    }
    catch {
        Write-Host "监测网络带宽时出错: $_" -ForegroundColor Red
        return $null
    }
}

# 函数：监测RDP性能
function Monitor-RDPPerformance {
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        
        # 测量网络延迟
        $latency = Measure-NetworkLatency -ComputerName $RDPServer -Port $RDPPort
        
        # 获取UDP状态
        $udpStatus = Get-RDPUDPStatus
        
        # 获取RDP连接状态
        $connectionStatus = Get-RDPConnectionStatus
        $tcpConnections = $connectionStatus.TCPConnections
        $udpConnections = $connectionStatus.UDPConnections
        
        # 记录到性能日志文件
        "$timestamp,$latency,$udpStatus,$tcpConnections,$udpConnections" | 
            Out-File -FilePath $PerformanceLogFile -Append -Encoding utf8
        
        # 输出到控制台
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - RDP性能指标:" -ForegroundColor Magenta
        Write-Host "  延迟: $(if ($latency) { "$latency ms" } else { "无法测量" })" -ForegroundColor Magenta
        Write-Host "  UDP状态: $udpStatus" -ForegroundColor Magenta
        Write-Host "  TCP连接数: $tcpConnections" -ForegroundColor Magenta
        Write-Host "  UDP连接数: $udpConnections" -ForegroundColor Magenta
        
        # 创建进度条显示延迟
        if ($latency) {
            # 将延迟映射到0-100的范围，假设500ms是100%
            $latencyPct = [math]::Min(100, ($latency / 5))
            Write-Progress -Activity "RDP性能" -Status "延迟: $latency ms" -Id 4 -PercentComplete $latencyPct
        }
        
        return @{
            Latency = $latency
            UDPStatus = $udpStatus
            TCPConnections = $tcpConnections
            UDPConnections = $udpConnections
        }
    }
    catch {
        Write-Host "监测RDP性能时出错: $_" -ForegroundColor Red
        return $null
    }
}

# 主监测循环
Write-Host "开始RDP连接高级性能监测..." -ForegroundColor Cyan
Write-Host "状态日志文件: $StatusLogFile" -ForegroundColor Cyan
Write-Host "带宽日志文件: $BandwidthLogFile" -ForegroundColor Cyan
Write-Host "性能日志文件: $PerformanceLogFile" -ForegroundColor Cyan
Write-Host "监测间隔: $MonitorInterval 秒" -ForegroundColor Cyan
Write-Host "RDP服务器: $RDPServer" -ForegroundColor Cyan
Write-Host "按 Ctrl+C 停止监测" -ForegroundColor Cyan
Write-Host "-------------------------------------------" -ForegroundColor Cyan

$count = 0
do {
    # 监测RDP性能
    $performanceData = Monitor-RDPPerformance
    
    # 监测网络带宽
    $bandwidthData = Monitor-NetworkBandwidth
    
    # 显示综合信息
    if ($performanceData -and $bandwidthData) {
        Write-Host "-------------------------------------------" -ForegroundColor DarkGray
        Write-Host "RDP性能综合报告:" -ForegroundColor White
        Write-Host "  延迟: $(if ($performanceData.Latency) { "$($performanceData.Latency) ms" } else { "无法测量" })" -ForegroundColor White
        Write-Host "  UDP状态: $($performanceData.UDPStatus)" -ForegroundColor White
        Write-Host "  带宽: $($bandwidthData.KbpsTotal) Kbps (↑$($bandwidthData.KbpsSent) ↓$($bandwidthData.KbpsReceived))" -ForegroundColor White
        Write-Host "-------------------------------------------" -ForegroundColor DarkGray
    }
    
    # 增加计数器（如果不是持续监测）
    if (-not $Continuous) {
        $count++
        Write-Host "已完成 $count/$SampleCount 次监测" -ForegroundColor DarkGray
    }
    
    # 等待指定的间隔时间
    if ($Continuous -or $count -lt $SampleCount) {
        Start-Sleep -Seconds $MonitorInterval
    }
} while ($Continuous -or $count -lt $SampleCount)

# 完成监测
Write-Progress -Activity "RDP监测" -Status "已完成" -Completed
Write-Host "RDP连接高级性能监测已完成。日志文件保存在: $LogFilePath" -ForegroundColor Green
