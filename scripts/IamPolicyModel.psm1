<#
    Simplified IAM policy evaluation MODEL for local POCs. NOT AWS.

    Evaluates the policy JSON rendered by Terraform (from offline plans):
      - identity policies: explicit Deny > Allow > implicit deny
      - Action / NotAction with * and ? wildcards (case-insensitive)
      - Resource with wildcards and the ${aws:username} policy variable
      - Condition: only "Bool" and "StringEquals" on keys supplied in the request
        context (e.g. aws:MultiFactorAuthPresent, iam:PassedToService); a missing
        key or any other operator => no match
      - trust policies: Principal.AWS exact ARN, account root, or "*"
      - AssumeRole = identity side AND trust side (same-account exception when
        the trust policy names the caller explicitly)

    NOT modelled: SCPs/RCPs, permission boundaries, session policies, resource
    policies other than trust, other condition operators, NotPrincipal,
    NotResource. Real behaviour is verified only by the REAL AWS POC.
#>

function ConvertTo-List {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Test-IamPattern {
    param([string]$Pattern, [string]$Value, [switch]$IgnoreCase)
    $regex = '^' + ([regex]::Escape($Pattern) -replace '\\\*', '.*' -replace '\\\?', '.') + '$'
    if ($IgnoreCase) { return [regex]::IsMatch($Value, $regex, 'IgnoreCase') }
    return [regex]::IsMatch($Value, $regex)
}

function Resolve-PolicyVariables {
    param([string]$Text, [hashtable]$Context)
    if ($Context.ContainsKey('Username')) {
        $Text = $Text.Replace('${aws:username}', $Context.Username)
    }
    return $Text
}

function Test-Conditions {
    param($Condition, [hashtable]$Context)
    if ($null -eq $Condition) { return $true }
    foreach ($operator in $Condition.PSObject.Properties) {
        # Bool and StringEquals: exact value match, but compared CASE-INSENSITIVELY
        # (PowerShell -contains). AWS StringEquals is case-sensitive - a known,
        # documented simplification of this model; all test values use canonical case.
        if (@('Bool', 'StringEquals') -notcontains $operator.Name) { return $false }
        foreach ($key in $operator.Value.PSObject.Properties) {
            if (-not $Context.ContainsKey('ConditionKeys')) { return $false }
            $supplied = $Context.ConditionKeys[$key.Name]
            if ($null -eq $supplied) { return $false }
            $expected = ConvertTo-List $key.Value
            if (-not ($expected -contains "$supplied")) { return $false }
        }
    }
    return $true
}

function Test-StatementMatch {
    param($Statement, [string]$Action, [string]$Resource, [hashtable]$Context)

    $actionMatch = $false
    if ($null -ne $Statement.Action) {
        foreach ($p in (ConvertTo-List $Statement.Action)) {
            if (Test-IamPattern -Pattern $p -Value $Action -IgnoreCase) { $actionMatch = $true }
        }
    }
    elseif ($null -ne $Statement.NotAction) {
        $actionMatch = $true
        foreach ($p in (ConvertTo-List $Statement.NotAction)) {
            if (Test-IamPattern -Pattern $p -Value $Action -IgnoreCase) { $actionMatch = $false }
        }
    }
    if (-not $actionMatch) { return $false }

    $resourceMatch = $false
    foreach ($p in (ConvertTo-List $Statement.Resource)) {
        $resolved = Resolve-PolicyVariables -Text $p -Context $Context
        if (Test-IamPattern -Pattern $resolved -Value $Resource) { $resourceMatch = $true }
    }
    if (-not $resourceMatch) { return $false }

    return (Test-Conditions -Condition $Statement.Condition -Context $Context)
}

function Get-IdentityDecision {
    <#
    .OUTPUTS
        'ExplicitDeny' | 'Allow' | 'ImplicitDeny'
    #>
    param([object[]]$Policies, [string]$Action, [string]$Resource, [hashtable]$Context = @{})
    $allowed = $false
    foreach ($policy in (ConvertTo-List $Policies)) {
        foreach ($st in (ConvertTo-List $policy.Statement)) {
            if (Test-StatementMatch -Statement $st -Action $Action -Resource $Resource -Context $Context) {
                if ($st.Effect -eq 'Deny') { return 'ExplicitDeny' }
                if ($st.Effect -eq 'Allow') { $allowed = $true }
            }
        }
    }
    if ($allowed) { return 'Allow' }
    return 'ImplicitDeny'
}

function Get-AccountFromArn {
    param([string]$Arn)
    return ($Arn -split ':')[4]
}

function Test-PrincipalMatch {
    param([string]$TrustedPrincipal, [string]$CallerArn)
    if ($TrustedPrincipal -eq '*') { return $true }
    if ($TrustedPrincipal -match '^arn:aws:iam::(\d{12}):root$') {
        return ((Get-AccountFromArn $CallerArn) -eq $Matches[1])
    }
    if ($TrustedPrincipal -match '^\d{12}$') {
        return ((Get-AccountFromArn $CallerArn) -eq $TrustedPrincipal)
    }
    return ($TrustedPrincipal -eq $CallerArn)
}

function Get-TrustDecision {
    <#
    .OUTPUTS
        @{ Decision = 'Allow'|'Deny'; Explicit = <bool: caller named by exact ARN> }
    #>
    param($TrustPolicy, [string]$CallerArn, [hashtable]$Context = @{})
    $allowed = $false
    $explicit = $false
    foreach ($st in (ConvertTo-List $TrustPolicy.Statement)) {
        $actions = ConvertTo-List $st.Action
        $actionOk = $false
        foreach ($a in $actions) {
            if (Test-IamPattern -Pattern $a -Value 'sts:AssumeRole' -IgnoreCase) { $actionOk = $true }
        }
        if (-not $actionOk) { continue }
        if (-not (Test-Conditions -Condition $st.Condition -Context $Context)) { continue }

        $principals = @()
        if ($st.Principal -is [string]) { $principals = @($st.Principal) }
        elseif ($null -ne $st.Principal.AWS) { $principals = ConvertTo-List $st.Principal.AWS }

        foreach ($p in $principals) {
            if (Test-PrincipalMatch -TrustedPrincipal $p -CallerArn $CallerArn) {
                if ($st.Effect -eq 'Deny') { return @{ Decision = 'Deny'; Explicit = $false } }
                $allowed = $true
                if ($p -eq $CallerArn) { $explicit = $true }
            }
        }
    }
    $decision = 'Deny'
    if ($allowed) { $decision = 'Allow' }
    return @{ Decision = $decision; Explicit = $explicit }
}

function Test-AssumeRole {
    <#
    .PARAMETER IsAccountRoot
        Caller is an account root user (identity policies do not restrict root).
    .OUTPUTS
        @{ Allowed = <bool>; Identity = <decision>; Trust = <decision> }
    #>
    param(
        [string]$CallerArn,
        [object[]]$CallerPolicies,
        [string]$TargetRoleArn,
        $TargetTrustPolicy,
        [hashtable]$Context = @{},
        [switch]$IsAccountRoot
    )
    $identity = 'Allow'
    if (-not $IsAccountRoot) {
        $identity = Get-IdentityDecision -Policies $CallerPolicies -Action 'sts:AssumeRole' -Resource $TargetRoleArn -Context $Context
    }
    $trust = Get-TrustDecision -TrustPolicy $TargetTrustPolicy -CallerArn $CallerArn -Context $Context
    $sameAccount = ((Get-AccountFromArn $CallerArn) -eq (Get-AccountFromArn $TargetRoleArn))

    $allowed = $false
    if ($identity -ne 'ExplicitDeny' -and $trust.Decision -eq 'Allow') {
        if ($identity -eq 'Allow') { $allowed = $true }
        elseif ($sameAccount -and $trust.Explicit) { $allowed = $true }
    }
    return @{ Allowed = $allowed; Identity = $identity; Trust = $trust.Decision }
}

Export-ModuleMember -Function Get-IdentityDecision, Get-TrustDecision, Test-AssumeRole, Test-IamPattern
