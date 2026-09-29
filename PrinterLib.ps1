# PrinterLib.ps1 - vendor-neutral printer probing for Windows PowerShell 5.1+
#
# Four independent ways to ask a printer what is wrong, in order of how
# universal they are:
#
#   1. IPP  (RFC 8011, port 631)  - every modern network printer. Best default.
#   2. SNMP (RFC 3805 Printer MIB, UDP 161) - near-universal, works when the
#      printer's web UI is locked down. Read here OUT OF BAND, so it reports
#      status without being allowed to gate printing.
#   3. Vendor EWS (port 80/443)  - richest data, different URLs per brand.
#   4. Raw 9100 connect          - proves the print path with zero interpretation.
#
# Everything normalizes to one shape so callers do not care which answered:
#
#   @{ Source; State; Blocking; Reasons[]; Supplies[]; Raw }
#
#   State    : idle | processing | stopped | unknown
#   Blocking : $true when a human must physically do something
#   Reasons  : normalized strings - media-empty, media-jam, door-open,
#              marker-supply-empty, offline, output-area-full, ...
#   Supplies : @{ Name; Level; Max; Percent; Measurable }
#
# Dot-source it:   . "$PSScriptRoot\PrinterLib.ps1"

Set-StrictMode -Version 2.0

# ===========================================================================
# BER / ASN.1 primitives (shared by SNMP)
# ===========================================================================

function New-BerLength {
    param([int]$Length)
    if ($Length -lt 0x80) { return [byte[]]@($Length) }
    $bytes = @()
    $n = $Length
    while ($n -gt 0) { $bytes = ,([byte]($n -band 0xFF)) + $bytes; $n = $n -shr 8 }
    return [byte[]](@([byte](0x80 -bor $bytes.Count)) + $bytes)
}

function New-BerTlv {
    param([byte]$Tag, [byte[]]$Value)
    if ($null -eq $Value) { $Value = [byte[]]@() }
    return [byte[]](@($Tag) + (New-BerLength $Value.Count) + $Value)
}

function New-BerInteger {
    param([int]$Value)
    if ($Value -eq 0) { return New-BerTlv 0x02 ([byte[]]@(0)) }
    $bytes = @()
    $n = $Value
    while ($n -ne 0 -and $n -ne -1) { $bytes = ,([byte]($n -band 0xFF)) + $bytes; $n = $n -shr 8 }
    # Prepend 0x00 if the high bit would make a positive number look negative.
    if ($Value -gt 0 -and ($bytes[0] -band 0x80)) { $bytes = ,([byte]0) + $bytes }
    return New-BerTlv 0x02 ([byte[]]$bytes)
}

function ConvertTo-BerOid {
    param([string]$Oid)
    $parts = $Oid.Split('.') | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ }
    $bytes = @([byte](40 * $parts[0] + $parts[1]))
    foreach ($p in $parts[2..($parts.Count - 1)]) {
        if ($p -lt 0x80) { $bytes += [byte]$p; continue }
        # Base-128 varint, high bit set on all but the last septet.
        $stack = @()
        $n = $p
        while ($n -gt 0) { $stack = ,([byte]($n -band 0x7F)) + $stack; $n = $n -shr 7 }
        for ($i = 0; $i -lt $stack.Count - 1; $i++) { $bytes += [byte]($stack[$i] -bor 0x80) }
        $bytes += $stack[$stack.Count - 1]
    }
    return New-BerTlv 0x06 ([byte[]]$bytes)
}

function Read-BerTlv {
    # Reads one TLV at [ref]$Pos and advances it past the value.
    param([byte[]]$Buffer, [ref]$Pos)
    if ($Pos.Value -ge $Buffer.Length) { return $null }
    $tag = $Buffer[$Pos.Value]; $Pos.Value++
    $len = $Buffer[$Pos.Value]; $Pos.Value++
    if ($len -band 0x80) {
        $n = $len -band 0x7F
        $len = 0
        for ($i = 0; $i -lt $n; $i++) { $len = ($len -shl 8) -bor $Buffer[$Pos.Value]; $Pos.Value++ }
    }
    $start = $Pos.Value
    # NOTE: never write `$x = if (...) {...} else { [byte[]]@() }` here. PowerShell
    # collapses an empty array returned from a scriptblock to $null, and the next
    # GetString() call dies with "Array cannot be null".
    $value = [byte[]]@()
    if ($len -gt 0) { $value = [byte[]]$Buffer[$start..($start + $len - 1)] }
    $Pos.Value = $start + $len
    return [pscustomobject]@{ Tag = $tag; Length = $len; Value = [byte[]]$value; ValueStart = $start }
}

function ConvertFrom-BerInteger {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Count -eq 0) { return 0 }
    $v = 0
    foreach ($b in $Bytes) { $v = ($v -shl 8) -bor $b }
    return $v
}

function ConvertFrom-BerOid {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Count -eq 0) { return '' }
    $parts = @([int]([math]::Floor($Bytes[0] / 40)), [int]($Bytes[0] % 40))
    $n = 0
    for ($i = 1; $i -lt $Bytes.Count; $i++) {
        $n = ($n -shl 7) -bor ($Bytes[$i] -band 0x7F)
        if (-not ($Bytes[$i] -band 0x80)) { $parts += $n; $n = 0 }
    }
    return ($parts -join '.')
}

# ===========================================================================
# SNMP (RFC 3805 Printer MIB) - out-of-band status only
# ===========================================================================

$script:PrinterOids = @{
    sysDescr            = '1.3.6.1.2.1.1.1.0'
    sysName             = '1.3.6.1.2.1.1.5.0'
    hrPrinterStatus     = '1.3.6.1.2.1.25.3.5.1.1.1'
    hrPrinterErrorState = '1.3.6.1.2.1.25.3.5.1.2.1'
    prtGeneralSerial    = '1.3.6.1.2.1.43.5.1.1.17.1'
}

# hrPrinterDetectedErrorState is a bit string; bit 0 is the high bit of byte 0.
$script:PrinterErrorBits = @(
    'low-paper', 'media-empty', 'low-toner', 'marker-supply-empty',
    'door-open', 'media-jam', 'offline', 'service-requested',
    'input-tray-missing', 'output-tray-missing', 'marker-supply-missing',
    'output-area-full', 'input-tray-empty', 'overdue-prevent-maint'
)

function Invoke-SnmpGet {
    <#
      .SYNOPSIS
        Raw SNMPv2c GET. No modules, no external binaries.
      .OUTPUTS
        Hashtable of OID -> value (string/int), or $null if no response.
    #>
    param(
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][string[]]$Oids,
        [string]$Community = 'public',
        [int]$TimeoutMs = 2000,
        [int]$Port = 161
    )

    $varbinds = @()
    foreach ($o in $Oids) {
        $varbinds += New-BerTlv 0x30 ([byte[]]((ConvertTo-BerOid $o) + (New-BerTlv 0x05 ([byte[]]@()))))
    }
    $vbList  = New-BerTlv 0x30 ([byte[]]($varbinds | ForEach-Object { $_ }))
    $reqId   = Get-Random -Minimum 1 -Maximum 2147483000
    $pdu     = New-BerTlv 0xA0 ([byte[]](
                  (New-BerInteger $reqId) + (New-BerInteger 0) + (New-BerInteger 0) + $vbList))
    $comm    = New-BerTlv 0x04 ([Text.Encoding]::ASCII.GetBytes($Community))
    $message = New-BerTlv 0x30 ([byte[]]((New-BerInteger 1) + $comm + $pdu))   # version 1 = SNMPv2c

    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($IPAddress, $Port)
        [void]$udp.Send($message, $message.Length)
        $remote = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), 0
        $resp = $udp.Receive([ref]$remote)
    } catch {
        return $null
    } finally {
        if ($udp) { $udp.Close() }
    }

    # Walk down to the varbind list and pull each OID/value pair.
    $pos = [ref]0
    $seq = Read-BerTlv $resp $pos
    if ($null -eq $seq) { return $null }
    $inner = [ref]$seq.ValueStart
    [void](Read-BerTlv $resp $inner)     # version
    [void](Read-BerTlv $resp $inner)     # community
    $pduTlv = Read-BerTlv $resp $inner
    if ($null -eq $pduTlv) { return $null }

    $p = [ref]$pduTlv.ValueStart
    [void](Read-BerTlv $resp $p)         # request-id
    $errStatus = Read-BerTlv $resp $p    # error-status
    [void](Read-BerTlv $resp $p)         # error-index
    if ((ConvertFrom-BerInteger $errStatus.Value) -ne 0) { return @{} }

    $vbl = Read-BerTlv $resp $p
    if ($null -eq $vbl) { return @{} }

    $result = @{}
    $q = [ref]$vbl.ValueStart
    $end = $vbl.ValueStart + $vbl.Length
    while ($q.Value -lt $end) {
        $vb = Read-BerTlv $resp $q
        if ($null -eq $vb) { break }
        $r = [ref]$vb.ValueStart
        $oidTlv = Read-BerTlv $resp $r
        $valTlv = Read-BerTlv $resp $r
        if ($null -eq $oidTlv -or $null -eq $valTlv) { break }
        $oid = ConvertFrom-BerOid $oidTlv.Value
        switch ($valTlv.Tag) {
            0x02 { $result[$oid] = ConvertFrom-BerInteger $valTlv.Value }          # INTEGER
            0x41 { $result[$oid] = ConvertFrom-BerInteger $valTlv.Value }          # Counter32
            0x42 { $result[$oid] = ConvertFrom-BerInteger $valTlv.Value }          # Gauge32
            0x43 { $result[$oid] = ConvertFrom-BerInteger $valTlv.Value }          # TimeTicks
            0x04 { $result[$oid] = [Text.Encoding]::UTF8.GetString($valTlv.Value) }# OCTET STRING
            0x06 { $result[$oid] = ConvertFrom-BerOid $valTlv.Value }              # OID
            0x05 { $result[$oid] = $null }                                          # NULL
            default {
                # noSuchObject (0x80) / noSuchInstance (0x81) / endOfMibView (0x82)
                if ($valTlv.Tag -ge 0x80) { $result[$oid] = $null }
                else { $result[$oid] = [Text.Encoding]::UTF8.GetString($valTlv.Value) }
            }
        }
    }
    return $result
}

function Get-PrinterStatusViaSnmp {
    param([Parameter(Mandatory)][string]$IPAddress, [string]$Community = 'public')

    $core = Invoke-SnmpGet -IPAddress $IPAddress -Community $Community -Oids @(
        $script:PrinterOids.sysDescr,
        $script:PrinterOids.hrPrinterStatus,
        $script:PrinterOids.hrPrinterErrorState
    )
    if ($null -eq $core -or $core.Count -eq 0) { return $null }

    $stateNum = $core[$script:PrinterOids.hrPrinterStatus]
    $state = 'unknown'
    switch ($stateNum) {
        1 { $state = 'unknown' }
        2 { $state = 'idle' }        # "running" in the MIB; idle for our purposes
        3 { $state = 'processing' }
        4 { $state = 'processing' }  # warmup
        5 { $state = 'stopped' }
    }

    # Decode hrPrinterDetectedErrorState, a bit string delivered as octets.
    $reasons = @()
    $errRaw = $core[$script:PrinterOids.hrPrinterErrorState]
    if ($errRaw -is [string] -and $errRaw.Length -gt 0) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($errRaw)
        for ($bit = 0; $bit -lt $script:PrinterErrorBits.Count; $bit++) {
            $byteIdx = [math]::Floor($bit / 8)
            if ($byteIdx -ge $bytes.Count) { break }
            $mask = 0x80 -shr ($bit % 8)
            if ($bytes[$byteIdx] -band $mask) { $reasons += $script:PrinterErrorBits[$bit] }
        }
    }

    # Supplies: prtMarkerSuppliesDescription/.Level/.MaxCapacity, indices 1..12.
    # Chunked deliberately: a single GET with 36 varbinds exceeds the agent's
    # response size limit, which answers tooBig (error-status 1) and yields
    # nothing at all. Six OIDs per request is well inside every agent's budget.
    $supplies = @()
    $sup = @{}
    # One supply index per request (3 varbinds). Two indices per request still
    # lost entries on a real M283cdw - some agents answer partially rather than
    # signalling tooBig, so the only safe chunk size is small.
    # Stops after 3 consecutive empty descriptions rather than always doing 12.
    $misses = 0
    for ($i = 1; $i -le 12; $i++) {
        $chunk = @(
            "1.3.6.1.2.1.43.11.1.1.6.1.$i"   # description
            "1.3.6.1.2.1.43.11.1.1.8.1.$i"   # max capacity
            "1.3.6.1.2.1.43.11.1.1.9.1.$i"   # current level
        )
        $part = Invoke-SnmpGet -IPAddress $IPAddress -Community $Community -Oids $chunk
        if ($part -and -not [string]::IsNullOrWhiteSpace($part["1.3.6.1.2.1.43.11.1.1.6.1.$i"])) {
            foreach ($k in $part.Keys) { $sup[$k] = $part[$k] }
            $misses = 0
        } else {
            $misses++
            if ($misses -ge 3 -and $i -gt 4) { break }
        }
    }
    if ($sup.Count -gt 0) {
        for ($i = 1; $i -le 12; $i++) {
            $d = $sup["1.3.6.1.2.1.43.11.1.1.6.1.$i"]
            if ([string]::IsNullOrWhiteSpace($d)) { continue }
            $max = $sup["1.3.6.1.2.1.43.11.1.1.8.1.$i"]
            $cur = $sup["1.3.6.1.2.1.43.11.1.1.9.1.$i"]
            # Negative sentinels: -1 unknown, -2 unrestricted, -3 "some remaining".
            $pct = $null
            $measurable = $false
            if ($cur -is [int] -and $max -is [int] -and $cur -ge 0 -and $max -gt 0) {
                $pct = [math]::Round(100.0 * $cur / $max)
                $measurable = $true
            }
            $supplies += [pscustomobject]@{
                Name = $d; Level = $cur; Max = $max; Percent = $pct; Measurable = $measurable
            }
        }
    }

    return [pscustomobject]@{
        Source     = 'SNMP'
        State      = $state
        Blocking   = [bool](@($reasons | Where-Object { $_ -in 'media-empty','media-jam','door-open','marker-supply-empty','output-area-full','input-tray-missing','service-requested' }).Count)
        Reasons    = $reasons
        Supplies   = $supplies
        Identity   = $core[$script:PrinterOids.sysDescr]
        Raw        = $core
    }
}

# ===========================================================================
# IPP (RFC 8011) - the real universal layer
# ===========================================================================

function New-IppAttribute {
    param([byte]$ValueTag, [string]$Name, [string]$Value)
    $nameBytes = [Text.Encoding]::UTF8.GetBytes($Name)
    $valBytes  = [Text.Encoding]::UTF8.GetBytes($Value)
    $out = @($ValueTag)
    $out += [byte](($nameBytes.Count -shr 8) -band 0xFF); $out += [byte]($nameBytes.Count -band 0xFF)
    $out += $nameBytes
    $out += [byte](($valBytes.Count -shr 8) -band 0xFF);  $out += [byte]($valBytes.Count -band 0xFF)
    $out += $valBytes
    return [byte[]]$out
}

function New-IppAdditionalValue {
    # An attribute with a zero-length name continues the previous attribute.
    param([byte]$ValueTag, [string]$Value)
    return New-IppAttribute -ValueTag $ValueTag -Name '' -Value $Value
}

function Invoke-IppGetPrinterAttributes {
    <#
      .SYNOPSIS
        IPP Get-Printer-Attributes (operation 0x000B) over HTTP on 631.
      .DESCRIPTION
        Tries the common IPP resource paths. Returns a normalized status object,
        or $null when the printer does not answer IPP at all.
    #>
    param(
        [Parameter(Mandatory)][string]$IPAddress,
        [int]$Port = 631,
        [int]$TimeoutSec = 8
    )

    # Different vendors expose IPP at different paths; try the usual suspects.
    $paths = @('/ipp/print', '/ipp/printer', '/printers/ipp', '/', '/ipp')

    foreach ($path in $paths) {
        $uri = "ipp://$IPAddress`:$Port$path"
        $body = @()
        $body += [byte]0x02; $body += [byte]0x00              # IPP 2.0
        $body += [byte]0x00; $body += [byte]0x0B              # Get-Printer-Attributes
        $body += [byte]0x00; $body += [byte]0x00; $body += [byte]0x00; $body += [byte]0x01  # request-id
        $body += [byte]0x01                                    # operation-attributes-tag
        $body += New-IppAttribute 0x47 'attributes-charset' 'utf-8'
        $body += New-IppAttribute 0x48 'attributes-natural-language' 'en-us'
        $body += New-IppAttribute 0x45 'printer-uri' $uri
        $body += New-IppAttribute 0x44 'requested-attributes' 'printer-state'
        foreach ($a in @('printer-state-reasons','printer-state-message','printer-is-accepting-jobs',
                         'printer-make-and-model','printer-info','queued-job-count',
                         'marker-names','marker-levels','marker-high-levels','marker-low-levels',
                         'marker-colors','marker-types','printer-alert','printer-alert-description')) {
            $body += New-IppAdditionalValue 0x44 $a
        }
        $body += [byte]0x03                                    # end-of-attributes-tag

        try {
            $req = [System.Net.HttpWebRequest]::Create("http://$IPAddress`:$Port$path")
            $req.Method = 'POST'
            $req.ContentType = 'application/ipp'
            $req.Timeout = $TimeoutSec * 1000
            $req.ReadWriteTimeout = $TimeoutSec * 1000
            $req.ContentLength = $body.Count
            $stream = $req.GetRequestStream()
            $stream.Write([byte[]]$body, 0, $body.Count)
            $stream.Close()

            $resp = $req.GetResponse()
            $ms = New-Object System.IO.MemoryStream
            $resp.GetResponseStream().CopyTo($ms)
            $resp.Close()
            $bytes = $ms.ToArray()
            if ($bytes.Count -lt 9) { continue }

            $attrs = Read-IppAttributes -Buffer $bytes
            if ($attrs.Count -eq 0) { continue }
            return ConvertTo-NormalizedIppStatus -Attributes $attrs -Path $path
        } catch {
            continue
        }
    }
    return $null
}

function Read-IppAttributes {
    <#
      .SYNOPSIS
        Parses an IPP response body into an ordered name -> value[] map.
    #>
    param([byte[]]$Buffer)

    $attrs = [ordered]@{}
    $pos = 8                       # skip version(2) status(2) request-id(4)
    $lastName = $null

    while ($pos -lt $Buffer.Length) {
        $tag = $Buffer[$pos]; $pos++
        if ($tag -eq 0x03) { break }                      # end-of-attributes
        if ($tag -lt 0x10) { $lastName = $null; continue } # group delimiter
        if ($pos + 1 -ge $Buffer.Length) { break }

        $nameLen = ($Buffer[$pos] -shl 8) -bor $Buffer[$pos + 1]; $pos += 2
        if ($pos + $nameLen -gt $Buffer.Length) { break }
        $name = if ($nameLen -gt 0) { [Text.Encoding]::UTF8.GetString($Buffer, $pos, $nameLen) } else { $lastName }
        $pos += $nameLen

        if ($pos + 1 -ge $Buffer.Length) { break }
        $valLen = ($Buffer[$pos] -shl 8) -bor $Buffer[$pos + 1]; $pos += 2
        if ($pos + $valLen -gt $Buffer.Length) { break }
        # Same empty-array-collapses-to-null trap as in Read-BerTlv. Zero-length
        # values are normal in IPP (the no-value 0x13 and unknown 0x12 tags), so
        # this path is hit on nearly every real response.
        $rawVal = [byte[]]@()
        if ($valLen -gt 0) { $rawVal = [byte[]]$Buffer[$pos..($pos + $valLen - 1)] }
        $pos += $valLen

        $value = switch ($tag) {
            0x21 { ConvertFrom-BerInteger $rawVal }                       # integer
            0x23 { ConvertFrom-BerInteger $rawVal }                       # enum
            0x22 { [bool]($rawVal.Count -gt 0 -and $rawVal[0] -ne 0) }    # boolean
            0x12 { $null }                                                # unknown
            0x13 { $null }                                                # no-value
            0x10 { $null }                                                # unsupported
            default {
                if ($rawVal.Count -eq 0) { '' }
                else { [Text.Encoding]::UTF8.GetString([byte[]]$rawVal) } # text/keyword/uri/name
            }
        }

        if ($null -ne $name -and $name -ne '') {
            if ($attrs.Contains($name)) { $attrs[$name] = @($attrs[$name]) + $value }
            else { $attrs[$name] = @($value) }
            $lastName = $name
        }
    }
    return $attrs
}

function ConvertTo-NormalizedIppStatus {
    param([System.Collections.Specialized.OrderedDictionary]$Attributes, [string]$Path)

    $stateNum = if ($Attributes.Contains('printer-state')) { @($Attributes['printer-state'])[0] } else { 0 }
    $state = switch ($stateNum) { 3 { 'idle' } 4 { 'processing' } 5 { 'stopped' } default { 'unknown' } }

    $reasons = @()
    if ($Attributes.Contains('printer-state-reasons')) {
        foreach ($r in @($Attributes['printer-state-reasons'])) {
            if ([string]::IsNullOrWhiteSpace($r)) { continue }
            if ($r -eq 'none') { continue }
            # Strip the RFC 8011 severity suffix: media-empty-error -> media-empty
            $reasons += ($r -replace '-(report|warning|error)$', '')
        }
    }
    $reasons = @($reasons | Sort-Object -Unique)

    # Supplies come as parallel arrays: marker-names / marker-levels.
    $supplies = @()
    if ($Attributes.Contains('marker-names')) {
        $names  = @($Attributes['marker-names'])
        $levels = if ($Attributes.Contains('marker-levels')) { @($Attributes['marker-levels']) } else { @() }
        $highs  = if ($Attributes.Contains('marker-high-levels')) { @($Attributes['marker-high-levels']) } else { @() }
        for ($i = 0; $i -lt $names.Count; $i++) {
            $lvl = if ($i -lt $levels.Count) { $levels[$i] } else { $null }
            $max = if ($i -lt $highs.Count)  { $highs[$i]  } else { 100 }
            # -1 unknown, -2 unrestricted, -3 "some remaining but unquantified"
            $measurable = ($lvl -is [int] -and $lvl -ge 0)
            $pct = $null
            if ($measurable -and $max -is [int] -and $max -gt 0) { $pct = [math]::Round(100.0 * $lvl / $max) }
            $supplies += [pscustomobject]@{
                Name = $names[$i]; Level = $lvl; Max = $max; Percent = $pct; Measurable = $measurable
            }
        }
    }

    $blockers = @('media-empty','media-jam','door-open','cover-open','marker-supply-empty',
                  'output-area-full','input-tray-missing','media-needed','offline',
                  'shutdown','stopped-partly','moving-to-paused','paused')

    return [pscustomobject]@{
        Source       = "IPP$Path"
        State        = $state
        Blocking     = [bool](@($reasons | Where-Object { $_ -in $blockers }).Count)
        Reasons      = $reasons
        Supplies     = $supplies
        Identity     = $(if ($Attributes.Contains('printer-make-and-model')) { @($Attributes['printer-make-and-model'])[0] } else { $null })
        AcceptingJobs= $(if ($Attributes.Contains('printer-is-accepting-jobs')) { @($Attributes['printer-is-accepting-jobs'])[0] } else { $null })
        QueuedJobs   = $(if ($Attributes.Contains('queued-job-count')) { @($Attributes['queued-job-count'])[0] } else { $null })
        Message      = $(if ($Attributes.Contains('printer-state-message')) { @($Attributes['printer-state-message'])[0] } else { $null })
        Raw          = $Attributes
    }
}

# ===========================================================================
# Vendor web UI (EWS) - richest data, brand-specific URLs
# ===========================================================================

function Get-XmlNodeValue {
    <#
      .SYNOPSIS
        Reads a child element's text by local name, returning '' when absent.
      .DESCRIPTION
        Dot notation on an XML node throws under Set-StrictMode when the element
        is missing, and printer XML is full of conditionally-present elements -
        a missing element is often the answer you are looking for, not an error.
        Matches on local-name() so namespace prefixes do not matter.
    #>
    param($Node, [string]$Name)
    if ($null -eq $Node) { return '' }
    try {
        $n = $Node.SelectSingleNode(".//*[local-name()='$Name']")
        if ($null -eq $n) { return '' }
        return [string]$n.InnerText
    } catch { return '' }
}

$script:VendorSignatures = @(
    @{ Vendor = 'HP';       Match = 'hp\.com|hewlett|/hp/device|LEDM|DevMgmt' }
    @{ Vendor = 'Brother';  Match = 'brother|/general/status\.html' }
    @{ Vendor = 'Canon';    Match = 'canon|/portal_top\.html|CPCA' }
    @{ Vendor = 'Epson';    Match = 'epson|/PRESENTATION/|EpsonNet' }
    @{ Vendor = 'Xerox';    Match = 'xerox|/stat/|CentreWare' }
    @{ Vendor = 'Lexmark';  Match = 'lexmark|/cgi-bin/dynamic' }
    @{ Vendor = 'Kyocera';  Match = 'kyocera|/startwlm/|Command Center' }
    @{ Vendor = 'Ricoh';    Match = 'ricoh|/web/guest/' }
    @{ Vendor = 'Samsung';  Match = 'samsung|/sws/' }
    @{ Vendor = 'Dell';     Match = 'dell(?!.*inspiron)' }
    @{ Vendor = 'OKI';      Match = 'oki(?!.*doki)|/status\.htm' }
)

function Get-PrinterVendor {
    <#
      .SYNOPSIS
        Identifies the brand from the printer's own web UI.
      .DESCRIPTION
        Falls back to the SNMP sysDescr string when the web UI gives nothing.
    #>
    param([Parameter(Mandatory)][string]$IPAddress, [int]$TimeoutSec = 8)

    $evidence = $null
    foreach ($scheme in @('http', 'https')) {
        try {
            $r = Invoke-WebRequest "${scheme}://$IPAddress/" -UseBasicParsing -TimeoutSec $TimeoutSec
            $hay = "$($r.Content)`n$($r.Headers | Out-String)"
            foreach ($sig in $script:VendorSignatures) {
                if ($hay -match $sig.Match) {
                    return [pscustomobject]@{ Vendor = $sig.Vendor; Scheme = $scheme; Evidence = 'web UI' }
                }
            }
            $evidence = 'web UI responded but brand unrecognized'
        } catch { continue }
    }

    $snmp = Invoke-SnmpGet -IPAddress $IPAddress -Oids @($script:PrinterOids.sysDescr)
    if ($snmp -and $snmp[$script:PrinterOids.sysDescr]) {
        $d = $snmp[$script:PrinterOids.sysDescr]
        foreach ($sig in $script:VendorSignatures) {
            if ($d -match $sig.Match) {
                return [pscustomobject]@{ Vendor = $sig.Vendor; Scheme = 'snmp'; Evidence = $d }
            }
        }
        return [pscustomobject]@{ Vendor = 'Unknown'; Scheme = 'snmp'; Evidence = $d }
    }

    return [pscustomobject]@{ Vendor = 'Unknown'; Scheme = $null; Evidence = $evidence }
}

function Get-PrinterStatusViaEws {
    <#
      .SYNOPSIS
        Vendor-specific status. Currently deep support for HP (LEDM);
        other brands return the discovered settings URLs for a human to open.
      .NOTES
        IPP and SNMP already cover state and supplies for every brand. This
        exists for the extras - power settings, service menus, event logs -
        that only the vendor's own interface exposes.
    #>
    param([Parameter(Mandatory)][string]$IPAddress, [string]$Vendor, [int]$TimeoutSec = 10)

    if (-not $Vendor) { $Vendor = (Get-PrinterVendor -IPAddress $IPAddress).Vendor }

    if ($Vendor -eq 'HP') {
        try {
            $sx = [xml](Invoke-WebRequest "http://$IPAddress/DevMgmt/ProductStatusDyn.xml" -UseBasicParsing -TimeoutSec $TimeoutSec).Content
            $state = @($sx.ProductStatusDyn.Status.StatusCategory)[0]
            $alerts = @($sx.SelectNodes('//*[local-name()="ProductStatusAlertID"]') |
                        ForEach-Object { $_.'#text' } | Sort-Object -Unique)

            $supplies = @()
            try {
                $cx = [xml](Invoke-WebRequest "http://$IPAddress/DevMgmt/ConsumableConfigDyn.xml" -UseBasicParsing -TimeoutSec $TimeoutSec).Content
                foreach ($c in $cx.ConsumableConfigDyn.ConsumableInfo) {
                    # Use Get-XmlNodeValue, not dot notation. Under Set-StrictMode
                    # a missing XML property THROWS rather than returning $null,
                    # and these elements are exactly the ones that go missing on
                    # third-party cartridges - so dot notation fails on the very
                    # case this code exists to detect.
                    # Two definitive markers, in order of reliability:
                    #
                    #   DataCollectionValid = false  -> the printer is telling you
                    #        outright that it cannot gather real data for this
                    #        cartridge. The percentage is extrapolated from page
                    #        counts and carries no information.
                    #
                    #   ConsumableLifeState contains 'clone' -> HP has identified
                    #        the cartridge as non-genuine.
                    #
                    # Do NOT rely on ConsumableUniqueID / MeasuredQuantityState
                    # being absent - plenty of models omit them on genuine
                    # cartridges too, so absence proves nothing.
                    $valid = Get-XmlNodeValue $c 'DataCollectionValid'
                    $life  = Get-XmlNodeValue $c 'ConsumableLifeState'
                    $clone = ($life -match '(?i)clone|counterfeit|non.?genuine')
                    $measurable = -not (($valid -match '(?i)^false$') -or $clone)

                    $pct = Get-XmlNodeValue $c 'ConsumablePercentageLevelRemaining'
                    $supplies += [pscustomobject]@{
                        Name       = (Get-XmlNodeValue $c 'ConsumableLabelCode')
                        Level      = $pct
                        Max        = 100
                        Percent    = $pct
                        Measurable = $measurable
                        Genuine    = -not $clone
                        Part       = (Get-XmlNodeValue $c 'ProductNumber')
                        Installed  = (Get-XmlNodeValue $c 'Installation')
                    }
                }
            } catch { }

            $map = @{
                'trayEmptyOrOpen' = 'media-empty'; 'jamInPrinter' = 'media-jam'
                'doorOpen' = 'door-open'; 'cartridgeMissing' = 'marker-supply-missing'
                'outputBinFull' = 'output-area-full'; 'cartridgeVeryLow' = 'marker-supply-low'
                'cartridgeLow' = 'marker-supply-low'
            }
            $reasons = @()
            foreach ($a in $alerts) {
                if ($a -eq 'genuineHP') { continue }   # advertising, not a fault
                if ($map.ContainsKey($a)) { $reasons += $map[$a] } else { $reasons += $a }
            }
            if ($map.ContainsKey($state)) { $reasons += $map[$state] }

            return [pscustomobject]@{
                Source = 'EWS/HP-LEDM'
                State = $(switch ($state) { 'ready' { 'idle' } 'processing' { 'processing' } default { 'stopped' } })
                Blocking = [bool](@($reasons | Where-Object { $_ -in 'media-empty','media-jam','door-open','marker-supply-missing','output-area-full' }).Count)
                Reasons = @($reasons | Sort-Object -Unique)
                Supplies = $supplies
                Identity = $null
                Raw = @{ StatusCategory = $state; Alerts = $alerts }
            }
        } catch { return $null }
    }

    return $null
}

function Get-PrinterWebUrls {
    <#
      .SYNOPSIS
        Best-known settings URLs per vendor, verified by probing.
      .DESCRIPTION
        Never hand someone a menu path from memory - probe it. Returns only
        URLs that actually answered 200.
    #>
    param([Parameter(Mandatory)][string]$IPAddress, [string]$Vendor)

    if (-not $Vendor) { $Vendor = (Get-PrinterVendor -IPAddress $IPAddress).Vendor }

    $candidates = switch ($Vendor) {
        'HP'      { @('/', '/hp/device/set_config_energy.html?tab=System&menu=EnergySettings',
                      '/hp/device/info_deviceStatus.html?tab=Home&menu=DevStatus',
                      '/DevMgmt/DiscoveryTree.xml', '/DevMgmt/ProductConfigCap.xml') }
        'Brother' { @('/', '/general/status.html', '/general/information.html', '/net/net/netconfig.html') }
        'Canon'   { @('/', '/portal_top.html', '/status.html') }
        'Epson'   { @('/', '/PRESENTATION/HTML/TOP/PRTINFO.HTML', '/PRESENTATION/ADVANCED/INFO_PRTINFO/TOP') }
        'Xerox'   { @('/', '/stat/index.dhtml', '/properties/index.dhtml') }
        'Lexmark' { @('/', '/cgi-bin/dynamic/printer/config/reports/deviceinfo.html') }
        'Kyocera' { @('/', '/startwlm/Start_Wlm.htm') }
        'Ricoh'   { @('/', '/web/guest/en/websys/status/getUnificationCounter.cgi') }
        default   { @('/', '/status.html', '/index.html') }
    }

    $found = @()
    foreach ($c in $candidates) {
        foreach ($scheme in @('http','https')) {
            try {
                $r = Invoke-WebRequest "${scheme}://$IPAddress$c" -UseBasicParsing -TimeoutSec 6
                if ($r.StatusCode -eq 200) {
                    $found += [pscustomobject]@{ Url = "${scheme}://$IPAddress$c"; Bytes = $r.Content.Length }
                    break
                }
            } catch { continue }
        }
    }
    return $found
}

function Find-PrinterSettingsPage {
    <#
      .SYNOPSIS
        Scrapes a printer's web UI for links matching a topic.
      .DESCRIPTION
        Use this instead of reciting a menu path from memory. Menu names and
        available options differ per model and firmware; a path that exists on
        one model is a dead end on another.
      .EXAMPLE
        Find-PrinterSettingsPage -IPAddress 10.0.0.5 -Topic 'energy|power|sleep'
    #>
    param(
        [Parameter(Mandatory)][string]$IPAddress,
        [string]$Topic = 'energy|power|sleep|network|security|setting',
        [int]$TimeoutSec = 10
    )
    try {
        $r = Invoke-WebRequest "http://$IPAddress/" -UseBasicParsing -TimeoutSec $TimeoutSec
    } catch { return @() }

    # Do NOT scrape href/src/action only. Printer web UIs routinely build their
    # navigation in JavaScript, so the settings pages live in quoted JS strings
    # with no HTML attribute around them. Scanning every quoted token that looks
    # like a page reference is what actually finds them.
    # (Real miss: an HP M283cdw's Energy Settings page appears only as a JS
    # string - href-only extraction returned 61 links and zero matches.)
    $esc     = [char]92                             # backslash
    # Doubled inside the class: a single backslash before ']' escapes the
    # bracket and leaves the character class unterminated.
    $class   = '[^"''`<>\s' + $esc + $esc + ']'     # URL chars, minus a JS escape
    $pattern = '(?i)["''`](' + $class + '*\.(?:html?|xml|cgi|dhtml|asp|jsp|php)(?:\?' + $class + '*)?)'
    $links = [regex]::Matches($r.Content, $pattern) |
             ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

    $hits = @($links | Where-Object { $_ -match $Topic } | ForEach-Object {
        # These are JS string literals, so a trailing backslash is an escape
        # character rather than part of the path. Strip entities and any tail.
        $u = ($_ -replace '&amp;', '&').TrimEnd($esc)
        if ($u -match '^https?://') { $u } else { "http://$IPAddress/" + $u.TrimStart('/') }
    })
    return @($hits | Sort-Object -Unique)
}

function Get-PrinterSettingOptions {
    <#
      .SYNOPSIS
        Reads a settings page and reports each dropdown's real options and
        which one is currently selected.
      .DESCRIPTION
        Answers "can this be set to X" with evidence instead of a guess. If the
        option is not in the list, it does not exist on this model.
    #>
    param([Parameter(Mandatory)][string]$Url, [int]$TimeoutSec = 10)
    try {
        $r = Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec $TimeoutSec
    } catch { return @() }

    $out = @()
    foreach ($m in [regex]::Matches($r.Content, '(?is)<select[^>]*name="([^"]+)"[^>]*>(.*?)</select>')) {
        $opts = foreach ($o in [regex]::Matches($m.Groups[2].Value, '(?is)<option([^>]*)>(.*?)</option>')) {
            [pscustomobject]@{
                Text     = ($o.Groups[2].Value -replace '<[^>]+>','').Trim()
                Selected = [bool]($o.Groups[1].Value -match 'selected')
            }
        }
        $out += [pscustomobject]@{ Field = $m.Groups[1].Value; Options = @($opts) }
    }
    foreach ($m in [regex]::Matches($r.Content, '(?is)<input[^>]*type="checkbox"[^>]*name="([^"]+)"[^>]*>')) {
        $out += [pscustomobject]@{
            Field = $m.Groups[1].Value
            Options = @([pscustomobject]@{ Text = 'checkbox'; Selected = [bool]($m.Value -match '(?i)checked') })
        }
    }
    return $out
}

# ===========================================================================
# Reachability + discovery
# ===========================================================================

function Test-PrinterPort {
    param([string]$IPAddress, [int]$Port, [int]$TimeoutMs = 1200)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($IPAddress, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $c.EndConnect($iar)
        return $true
    } catch { return $false } finally { $c.Close() }
}

function Test-PrinterReachability {
    param([Parameter(Mandatory)][string]$IPAddress)
    return [pscustomobject]@{
        IPAddress = $IPAddress
        Raw9100   = Test-PrinterPort $IPAddress 9100   # printing
        IPP631    = Test-PrinterPort $IPAddress 631    # IPP
        Http80    = Test-PrinterPort $IPAddress 80     # web UI
        Https443  = Test-PrinterPort $IPAddress 443
        LPD515    = Test-PrinterPort $IPAddress 515    # legacy LPR
        Ping      = (Test-Connection $IPAddress -Count 1 -Quiet -ErrorAction SilentlyContinue)
    }
}

function Send-PrinterRawTest {
    <#
      .SYNOPSIS
        Prints one page straight to port 9100, bypassing driver and spooler.
      .DESCRIPTION
        The cleanest possible split: if a page comes out, the network, port and
        print engine are all healthy and the fault is Windows-side. If nothing
        comes out, stop debugging Windows.
        PJL + PCL works on essentially all laser printers. Many inkjets ignore
        raw 9100 entirely - use -Force to try anyway.
    #>
    param([Parameter(Mandatory)][string]$IPAddress, [int]$Port = 9100, [switch]$Force)

    if (-not (Test-PrinterPort $IPAddress $Port)) {
        return [pscustomobject]@{ Sent = $false; Reason = "port $Port not reachable" }
    }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $text = "`e%-12345X@PJL`r`n@PJL ENTER LANGUAGE=PCL`r`n`eE RAW $Port DATA PATH TEST -- $stamp`r`n" +
            "If this page printed, the network, port and print engine are healthy.`r`n`f`eE`e%-12345X"
    $bytes = [Text.Encoding]::ASCII.GetBytes($text)
    $t = New-Object System.Net.Sockets.TcpClient
    try {
        $t.Connect($IPAddress, $Port)
        $s = $t.GetStream()
        $s.Write($bytes, 0, $bytes.Length)
        $s.Flush()
        Start-Sleep -Milliseconds 800
        return [pscustomobject]@{ Sent = $true; Bytes = $bytes.Length; Reason = 'ask whether a page came out' }
    } catch {
        return [pscustomobject]@{ Sent = $false; Reason = $_.Exception.Message }
    } finally { $t.Close() }
}

function Find-NetworkPrinter {
    <#
      .SYNOPSIS
        Discovers printers by SSDP/WSD and by sweeping the local subnet.
      .DESCRIPTION
        Use when a printer has moved IP or its address is unknown. The sweep is
        parallel and typically finishes a /24 in a few seconds.
    #>
    param(
        [string]$Subnet,                 # e.g. '192.168.1' - defaults to this host's
        [switch]$SkipSweep,
        [int]$TimeoutMs = 1000
    )

    $found = @{}

    # --- SSDP / WSD multicast discovery ---
    foreach ($st in @('urn:schemas-upnp-org:device:Printer:1',
                      'urn:schemas-upnp-org:device:PrinterBasic:1',
                      'ssdp:all')) {
        $udp = $null
        try {
            $udp = New-Object System.Net.Sockets.UdpClient
            $udp.Client.ReceiveTimeout = $TimeoutMs
            $msg = "M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 1`r`nST: $st`r`n`r`n"
            $b = [Text.Encoding]::ASCII.GetBytes($msg)
            $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse('239.255.255.250')), 1900
            [void]$udp.Send($b, $b.Length, $ep)
            $deadline = (Get-Date).AddMilliseconds($TimeoutMs * 2)
            while ((Get-Date) -lt $deadline) {
                $remote = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), 0
                try { [void]$udp.Receive([ref]$remote) } catch { break }
                $found[$remote.Address.ToString()] = 'SSDP'
            }
        } catch { } finally { if ($udp) { $udp.Close() } }
    }

    # --- Subnet sweep on the printing port ---
    if (-not $SkipSweep) {
        $subnets = @()
        if ($Subnet) {
            $subnets = @($Subnet)
        } else {
            # Do NOT just take the first IPv4 address. A developer machine
            # routinely has a dozen: WSL, VMware/VirtualBox host-only adapters,
            # Hyper-V vSwitches, VPN tunnels, Bluetooth PAN, link-local. Picking
            # the first one sweeps an empty virtual subnet and reports "no
            # printers found" while the printer sits on Wi-Fi.
            # (Real case: 14 addresses, first was a WSL vEthernet at 172.30.x.)
            $virtualAlias = 'vEthernet|VMware|VirtualBox|Hyper-V|Loopback|Bluetooth|Tailscale|ZeroTier|Npcap|TAP-|WireGuard|AnyConnect|Pseudo'
            $cands = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                     Where-Object {
                         $_.PrefixOrigin -ne 'WellKnown' -and
                         $_.IPAddress -notlike '169.254.*' -and
                         $_.IPAddress -ne '127.0.0.1' -and
                         $_.PrefixLength -ge 22 -and          # /22../30; skip huge ranges
                         $_.InterfaceAlias -notmatch $virtualAlias
                     }

            # An interface with a default gateway is a real network. Prefer those.
            $gw = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty InterfaceIndex -Unique)
            $ranked = @($cands | Sort-Object @{ Expression = { if ($gw -contains $_.InterfaceIndex) { 0 } else { 1 } } })

            foreach ($c in $ranked) {
                $s = ($c.IPAddress -split '\.')[0..2] -join '.'
                if ($subnets -notcontains $s) { $subnets += $s }
            }
        }

        foreach ($sn in $subnets) {
            $jobs = 1..254 | ForEach-Object {
                $addr = "$sn.$_"
                $c = New-Object System.Net.Sockets.TcpClient
                [pscustomobject]@{ IP = $addr; Client = $c; Async = $c.BeginConnect($addr, 9100, $null, $null) }
            }
            Start-Sleep -Milliseconds 1200
            foreach ($j in $jobs) {
                try {
                    if ($j.Async.IsCompleted) { $j.Client.EndConnect($j.Async); $found[$j.IP] = 'port 9100' }
                } catch { } finally { $j.Client.Close() }
            }
        }
    }

    # --- Identify what we found ---
    $results = @()
    foreach ($ip in ($found.Keys | Sort-Object)) {
        $reach = Test-PrinterReachability -IPAddress $ip
        if (-not ($reach.Raw9100 -or $reach.IPP631)) { continue }   # not a printer
        $v = Get-PrinterVendor -IPAddress $ip
        $results += [pscustomobject]@{
            IPAddress = $ip
            Vendor    = $v.Vendor
            Found     = $found[$ip]
            Raw9100   = $reach.Raw9100
            IPP631    = $reach.IPP631
            WebUI     = $(if ($reach.Http80) { "http://$ip" } elseif ($reach.Https443) { "https://$ip" } else { $null })
        }
    }
    return $results
}

# ===========================================================================
# Unified entry point
# ===========================================================================

function Get-PrinterDeviceStatus {
    <#
      .SYNOPSIS
        Asks the printer what is wrong, using whichever method answers.
      .DESCRIPTION
        Tries IPP first (most universal), then SNMP, then the vendor web UI.
        Returns the first authoritative answer plus every source that replied,
        so disagreements are visible rather than hidden.
    #>
    param(
        [Parameter(Mandatory)][string]$IPAddress,
        [string]$Community = 'public',
        [switch]$AllSources
    )

    $sources = @()
    $ipp = Invoke-IppGetPrinterAttributes -IPAddress $IPAddress
    if ($ipp) { $sources += $ipp }

    if ($AllSources -or -not $ipp) {
        $snmp = Get-PrinterStatusViaSnmp -IPAddress $IPAddress -Community $Community
        if ($snmp) { $sources += $snmp }
    }

    if ($AllSources -or $sources.Count -eq 0) {
        $v = Get-PrinterVendor -IPAddress $IPAddress
        $ews = Get-PrinterStatusViaEws -IPAddress $IPAddress -Vendor $v.Vendor
        if ($ews) { $sources += $ews }
    }

    if ($sources.Count -eq 0) { return $null }

    $primary = $sources[0]
    Add-Member -InputObject $primary -NotePropertyName 'AllSources' -NotePropertyValue $sources -Force
    return $primary
}
