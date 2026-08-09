<#
    Quest USB NCM Link
    ------------------
    Puts the headset's USB port into NCM (USB Ethernet) mode and gives the
    resulting link a working IPv4 configuration, so Steam Link runs over the
    cable instead of Wi-Fi.

    Why this works the way it does (measured on a Quest 2 "hollywood",
    Android 14, build 52202280028100150, USB gadget HAL V2_0):

      * "svc usb setFunctions ncm,adb" is ALWAYS rejected. UsbService calls
        Preconditions.checkArgument(UsbManager.areSettableFunctions(f)), and
        that requires exactly ONE function bit. Passing two throws
        IllegalArgumentException before the gadget HAL is ever reached.
        ADB does not need to be listed - UsbDeviceManager ORs it in by itself
        whenever adb_enabled is true. So the correct call is plain "ncm".

      * RNDIS is not an option on this hardware. The gadget HAL answers
        setCurrentUsbFunctionsCb with status:4 (ERROR) and the framework falls
        back to charging. NCM is the only network gadget available.

      * Android's Tethering service cannot address the link: the build ships
        tetherableNcmRegexs = [] (empty), which is the exact cause of
        "ERROR could not enable IpServer for function NCM" in logcat.
        That message is a red herring - it is not what makes the link work.

      * What DOES work: the Ethernet service has an interface filter of
        ((eth\d)|(usb\d)), so it claims usb0 as a CLIENT interface and runs a
        DHCP client on it. The headset sits there broadcasting DHCPDISCOVER
        forever. All that is missing is a DHCP server on the PC end - which is
        what this script provides. On lease, Android brings up a real ETHERNET
        network and routes over the cable.

      * The Ethernet network must become the DEFAULT network or apps will keep
        using Wi-Fi. Android only prefers it once it VALIDATES, which needs
        real internet - hence the NAT below. Without NAT you would have to turn
        the headset's Wi-Fi off instead.

      * Any active VpnService captures uid 0-99999 and swallows all app
        traffic regardless of routing. gnirehtet-based cable setups work
        exactly this way, so it is stopped first if present.
#>

[CmdletBinding()]
param(
    # Wi-Fi-off mode: rather than giving the headset internet through the cable
    # (which needs Windows NAT), switch the headset's Wi-Fi off so the cable is
    # its only route. Wi-Fi is switched back on when this script exits.
    # This is also the automatic fallback when Windows NAT is unavailable.
    # -NoInternet is accepted as an older name for the same switch.
    [Alias('NoInternet')]
    [switch]$WifiOff
)

$ErrorActionPreference = 'Continue'

# ----------------------------- configuration -----------------------------
$Subnet     = '192.168.42'
$PcIp       = "$Subnet.1"
$HeadsetIp  = "$Subnet.2"
$PrefixLen  = 24
$DnsServers = @('1.1.1.1', '8.8.8.8')   # NATed out; WinNAT has no DNS proxy
$LeaseSecs  = 3600
$NatName    = 'QuestNcmLink'
$FwRuleName = 'Quest NCM Link (USB)'
$VpnPackage = 'com.genymobile.gnirehtet'
# -------------------------------------------------------------------------

function Say([string]$m) { Write-Host "  $m" }
function Ok ([string]$m) { Write-Host "  $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "  $m" -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host "  $m" -ForegroundColor Red }

Write-Host ""
Write-Host "  Quest USB NCM Link" -ForegroundColor Cyan
Write-Host "  =================="
Write-Host ""

# State we need to undo on exit.
$script:Adb        = $null
$script:Serial     = $null
$script:AdapterIdx = $null
$script:NatMade    = $false
$script:FwMade     = $false
$script:IpMade     = $false
$script:DhcpJob    = $null
$script:WifiOffByUs = $false

function Restore-Everything {
    Write-Host ""
    Say "Restoring..."

    if ($script:DhcpJob) {
        Stop-Job  $script:DhcpJob -ErrorAction SilentlyContinue
        Remove-Job $script:DhcpJob -Force -ErrorAction SilentlyContinue
    }
    if ($script:NatMade) {
        Remove-NetNat -Name $NatName -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($script:FwMade) {
        Remove-NetFirewallRule -DisplayName $FwRuleName -ErrorAction SilentlyContinue
    }
    if ($script:IpMade -and $script:AdapterIdx) {
        Remove-NetIPAddress -InterfaceIndex $script:AdapterIdx -IPAddress $PcIp `
            -Confirm:$false -ErrorAction SilentlyContinue
        Set-NetIPInterface -InterfaceIndex $script:AdapterIdx -AddressFamily IPv4 `
            -Dhcp Enabled -ErrorAction SilentlyContinue
    }
    if ($script:Serial) {
        if ($script:WifiOffByUs) {
            & $script:Adb -s $script:Serial shell svc wifi enable 2>&1 | Out-Null
            Say "Headset Wi-Fi switched back on."
        }
        # Blank function list = back to charging (+ adb).
        & $script:Adb -s $script:Serial shell svc usb setFunctions 2>&1 | Out-Null
    }
    Ok "Done. USB is back to normal."
}

try {
    # --------------------------------------------------------------- 1. adb
    # Prefer a copy shipped next to this script so the package is self-
    # contained - no C:\Android folder and no system PATH editing. Only
    # adb.exe, AdbWinApi.dll and AdbWinUsbApi.dll are needed (~6.6 MB).
    $script:Adb = $null
    $candidates = @(
        (Join-Path $PSScriptRoot 'adb.exe'),
        (Join-Path $PSScriptRoot 'platform-tools\adb.exe'),
        (Join-Path $PSScriptRoot 'Android\platform-tools\adb.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $script:Adb = $c; break }
    }
    if (-not $script:Adb) {
        $onPath = Get-Command adb -ErrorAction SilentlyContinue
        if ($onPath) { $script:Adb = $onPath.Source }
    }
    if (-not $script:Adb) {
        Fail "[X] adb was not found."
        Say "    Put adb.exe, AdbWinApi.dll and AdbWinUsbApi.dll in the same"
        Say "    folder as this script, or have adb on your PATH."
        return
    }
    & $script:Adb start-server 2>&1 | Out-Null

    $script:Serial = & $script:Adb devices |
        Where-Object { $_ -match '^\S+\s+device\s*$' -and $_ -notmatch ':' } |
        ForEach-Object { ($_ -split '\s+')[0] } |
        Select-Object -First 1

    if (-not $script:Serial) {
        Fail "[X] No headset found on USB."
        Say "    - Is the cable plugged in?"
        Say "    - Did you accept 'Allow USB debugging' in the headset?"
        return
    }
    Say "[1/6] Headset on USB: $($script:Serial)"
    Say "      using adb: $($script:Adb)"

    # ------------------------------------------- 2. clear the old VPN tunnel
    $vpnRunning = (& $script:Adb -s $script:Serial shell pm list packages) -match [regex]::Escape($VpnPackage)
    if ($vpnRunning) {
        & $script:Adb -s $script:Serial shell am force-stop $VpnPackage 2>&1 | Out-Null
        Say "[2/6] Stopped the gnirehtet tunnel (it would capture all traffic)"
    } else {
        Say "[2/6] No gnirehtet tunnel to clear"
    }

    # ------------------------------------------------- 3. switch USB to NCM
    # Single function only - see the header comment.
    Say "[3/6] Switching USB to NCM..."
    & $script:Adb -s $script:Serial shell svc usb setFunctions ncm 2>&1 | Out-Null

    $adapter = $null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceDescription -match 'UsbNcm|NCM' -and $_.Status -eq 'Up' } |
            Select-Object -First 1
        if ($adapter) { break }
    }
    if (-not $adapter) {
        Fail "      Windows never showed a UsbNcm adapter."
        Say  "      Check Device Manager > Network adapters for a yellow flag."
        Say  "      Confirm the gadget came up on the headset with:"
        Say  "        adb shell svc usb getFunctions      (expect: ncm)"
        return
    }
    $script:AdapterIdx = $adapter.ifIndex
    $pcMac = ($adapter.MacAddress -replace '-', ':').ToLower()
    Ok "      Windows adapter: '$($adapter.Name)' ($($adapter.LinkSpeed))"

    # --------------------------------------------------- 4. address PC side
    Say "[4/6] Configuring the PC end ($PcIp/$PrefixLen)..."
    Get-NetIPAddress -InterfaceIndex $script:AdapterIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceIndex $script:AdapterIdx -AddressFamily IPv4 `
        -Dhcp Disabled -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $script:AdapterIdx -IPAddress $PcIp `
        -PrefixLength $PrefixLen -ErrorAction Stop | Out-Null
    $script:IpMade = $true

    # Steam's firewall rules usually cover Private but not Public networks.
    Set-NetConnectionProfile -InterfaceIndex $script:AdapterIdx `
        -NetworkCategory Private -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $FwRuleName -Direction Inbound -Action Allow `
        -RemoteAddress "$Subnet.0/24" -Profile Any -ErrorAction SilentlyContinue | Out-Null
    $script:FwMade = $true

    # Internet over the cable needs Windows NAT. The MSFT_NetNat CIM class
    # ships with Hyper-V, so Windows Home generally does not have it and
    # New-NetNat fails with "Invalid class". Check before trying, so the
    # message is something a user can act on.
    if (-not $WifiOff) {
        $natClass = Get-CimClass -Namespace root/StandardCimv2 `
            -ClassName MSFT_NetNat -ErrorAction SilentlyContinue
        if (-not $natClass) {
            Warn "      Windows NAT is not available on this PC."
            Warn "      (It ships with Hyper-V, so Windows Home usually"
            Warn "       does not have it. This is not a problem.)"
        } else {
            Get-NetNat -Name $NatName -ErrorAction SilentlyContinue |
                Remove-NetNat -Confirm:$false -ErrorAction SilentlyContinue
            try {
                New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix "$Subnet.0/24" `
                    -ErrorAction Stop | Out-Null
                $script:NatMade = $true
                Ok "      NAT is up - the headset gets internet over the cable"
            } catch {
                Warn "      Could not create NAT: $($_.Exception.Message)"
            }
        }
    }

    # ------------------------------------------------- 5. serve DHCP to usb0
    Say "[5/6] Serving DHCP on the link..."
    $script:DhcpJob = Start-Job -Name 'QuestNcmDhcp' -ArgumentList `
        $PcIp, $HeadsetIp, $PrefixLen, $DnsServers, $LeaseSecs, $pcMac -ScriptBlock {
        param($PcIp, $OfferIp, $PrefixLen, $DnsServers, $LeaseSecs, $PcMac)

        $srv = [Net.IPAddress]::Parse($PcIp)
        $off = [Net.IPAddress]::Parse($OfferIp)
        $mb  = New-Object byte[] 4
        for ($b = 0; $b -lt 4; $b++) {
            $bits = [Math]::Max(0, [Math]::Min(8, $PrefixLen - ($b * 8)))
            $mb[$b] = [byte](((0xFF -shl (8 - $bits)) -band 0xFF))
        }

        $rx = New-Object Net.Sockets.Socket('InterNetwork', 'Dgram', 'Udp')
        $rx.SetSocketOption('Socket', 'ReuseAddress', $true)
        $rx.EnableBroadcast = $true
        try { $rx.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, 67))) }
        catch { Write-Output "BIND-FAILED: $($_.Exception.Message)"; return }

        function New-Tx($ip) {
            $s = New-Object Net.Sockets.Socket('InterNetwork', 'Dgram', 'Udp')
            $s.SetSocketOption('Socket', 'ReuseAddress', $true)
            $s.EnableBroadcast = $true
            $s.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Parse($ip), 0)))
            return $s
        }
        $tx = $null

        function Get-Opt([byte[]]$p, [int]$code) {
            $i = 240
            while ($i -lt $p.Length) {
                $c = $p[$i]
                if ($c -eq 255) { return $null }
                if ($c -eq 0) { $i++; continue }
                $len = $p[$i + 1]
                if ($c -eq $code) { return $p[($i + 2)..($i + 1 + $len)] }
                $i += 2 + $len
            }
            return $null
        }

        function Build-Reply([byte[]]$req, [byte]$type) {
            $r = New-Object byte[] 320
            $r[0] = 2; $r[1] = 1; $r[2] = 6; $r[3] = 0
            [Array]::Copy($req, 4, $r, 4, 4)                       # xid
            [Array]::Copy($req, 10, $r, 10, 2)                     # flags
            [Array]::Copy($off.GetAddressBytes(), 0, $r, 16, 4)    # yiaddr
            [Array]::Copy($srv.GetAddressBytes(), 0, $r, 20, 4)    # siaddr
            [Array]::Copy($req, 28, $r, 28, 16)                    # chaddr
            $r[236] = 99; $r[237] = 130; $r[238] = 83; $r[239] = 99
            $o = 240
            $r[$o++] = 53; $r[$o++] = 1; $r[$o++] = $type
            $r[$o++] = 54; $r[$o++] = 4
            [Array]::Copy($srv.GetAddressBytes(), 0, $r, $o, 4); $o += 4
            $r[$o++] = 51; $r[$o++] = 4
            $lb = [BitConverter]::GetBytes([uint32]$LeaseSecs); [Array]::Reverse($lb)
            [Array]::Copy($lb, 0, $r, $o, 4); $o += 4
            $r[$o++] = 1; $r[$o++] = 4
            [Array]::Copy($mb, 0, $r, $o, 4); $o += 4
            $r[$o++] = 3; $r[$o++] = 4
            [Array]::Copy($srv.GetAddressBytes(), 0, $r, $o, 4); $o += 4
            $r[$o++] = 6; $r[$o++] = [byte](4 * $DnsServers.Count)
            foreach ($d in $DnsServers) {
                [Array]::Copy(([Net.IPAddress]::Parse($d)).GetAddressBytes(), 0, $r, $o, 4); $o += 4
            }
            $r[$o++] = 255
            return , $r[0..($o - 1)]
        }

        $buf = New-Object byte[] 1500
        Write-Output "DHCP server listening (offering $OfferIp)"

        while ($true) {
            if (-not $rx.Poll(1000000, 'SelectRead')) { continue }
            $remote = [Net.EndPoint](New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0))
            try { $n = $rx.ReceiveFrom($buf, [ref]$remote) } catch { continue }
            if ($n -lt 240) { continue }
            $pkt = $buf[0..($n - 1)]
            if ($pkt[0] -ne 1) { continue }
            $t = Get-Opt $pkt 53
            if (-not $t) { continue }

            $mac = ($pkt[28..33] | ForEach-Object { $_.ToString('x2') }) -join ':'
            if ($mac -eq $PcMac) { continue }      # Windows' own client on this NIC
            if ($t[0] -ne 1 -and $t[0] -ne 3) { continue }

            $isDiscover = ($t[0] -eq 1)
            $reply = Build-Reply $pkt $(if ($isDiscover) { 2 } else { 5 })

            # Renewals arrive unicast with ciaddr set; answer those directly.
            $ciaddr = [Net.IPAddress]::new([byte[]]$pkt[12..15])
            if (-not $isDiscover -and $ciaddr.ToString() -ne '0.0.0.0') {
                $dest = New-Object Net.IPEndPoint($ciaddr, 68)
            } else {
                $dest = New-Object Net.IPEndPoint([Net.IPAddress]::Broadcast, 68)
            }

            for ($try = 0; $try -lt 2; $try++) {
                try {
                    if (-not $tx) { $tx = New-Tx $PcIp }
                    [void]$tx.SendTo($reply, $dest)
                    Write-Output "$(if($isDiscover){'OFFER'}else{'ACK  '}) -> $mac"
                    break
                } catch {
                    # Interface may still be settling right after re-enumeration.
                    if ($tx) { $tx.Close(); $tx = $null }
                    Start-Sleep -Milliseconds 400
                }
            }
        }
    }

    # ------------------------------------------------ 6. wait for the lease
    Say "[6/6] Waiting for the headset to take the lease..."
    $leased = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 2
        $addr = & $script:Adb -s $script:Serial shell "ip -o -4 addr show usb0" 2>&1
        if ("$addr" -match [regex]::Escape($HeadsetIp)) { $leased = $true; break }
    }

    # Without NAT the cable cannot pass Android's internet check, so Wi-Fi
    # stays the default network and the cable goes unused. Switching Wi-Fi off
    # makes the cable the only route. Put back in Restore-Everything.
    if ($leased -and -not $script:NatMade) {
        Say "      No internet on the cable, so switching the headset's"
        Say "      Wi-Fi off to force traffic onto it."
        & $script:Adb -s $script:Serial shell svc wifi disable 2>&1 | Out-Null
        $script:WifiOffByUs = $true
        Start-Sleep -Seconds 5
    }

    Write-Host ""
    Write-Host "  ----------------------------------------------------------"
    if ($leased) {
        Ok "  Link is up."
        Write-Host ""
        Write-Host "        Headset : $HeadsetIp" -ForegroundColor White
        Write-Host "        This PC : $PcIp" -ForegroundColor White
        Write-Host ""

        $def = & $script:Adb -s $script:Serial shell "dumpsys connectivity" 2>&1 |
            Select-String '^Active default network'
        $eth = & $script:Adb -s $script:Serial shell "dumpsys connectivity" 2>&1 |
            Select-String 'Ethernet CONNECTED'

        if ($eth) { Ok "  Headset has an ETHERNET network on the cable." }
        Say "  $def"

        if ($script:NatMade) {
            Say  "  Give it ~15s to validate, then it becomes the default"
            Say  "  network on its own. You can leave Wi-Fi on."
        } else {
            Ok   "  Headset Wi-Fi is off, so the cable is its only route."
            Say  "  Steam Link does not need the headset to have internet."
            Say  "  Wi-Fi comes back when you press a key to exit."
        }
        Write-Host ""
        Say "  In Steam Link, connect to $PcIp"
    } else {
        Fail "  The headset never took a lease."
        Write-Host ""
        Say "  Check, in order:"
        Say "   - adb shell svc usb getFunctions           (expect: ncm)"
        Say "   - adb shell ip -o addr show usb0           (expect: an inet line)"
        Say "   - adb logcat -d | findstr DhcpClient       (expect: DHCPDISCOVER)"
        Say "   - Another DHCP server may own UDP 67 on this PC:"
        Say "       Get-NetUDPEndpoint -LocalPort 67"
        Receive-Job $script:DhcpJob | ForEach-Object { Say "   dhcp: $_" }
    }
    Write-Host "  ----------------------------------------------------------"

    Write-Host ""
    Write-Host "  =========================================================="
    Write-Host "  Leave this window open while you play."
    Write-Host "  Press any key here to restore normal USB mode."
    Write-Host "  =========================================================="
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
finally {
    Restore-Everything
}
