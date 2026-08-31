Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:AIChatConnectorTaskDescriptionPrefix = "AIChat Windows Codex Connector; managed-by=AIChat; sid="
$script:AIChatLocalSystemSid = "S-1-5-18"

function Get-AIChatCurrentSid {
    if ($env:OS -ne "Windows_NT") {
        throw "The AIChat Windows connector service requires Windows"
    }
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-AIChatLocalAppData {
    $path = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $path) { $path = $env:LOCALAPPDATA }
    if (-not $path) { throw "Cannot resolve LocalApplicationData for the current user" }
    return [IO.Path]::GetFullPath($path)
}

function Get-AIChatProtectedRoot {
    return [IO.Path]::GetFullPath((Join-Path (Get-AIChatLocalAppData) "AIChat"))
}

function Get-AIChatUserProfile {
    $path = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if (-not $path) { $path = $env:USERPROFILE }
    if (-not $path) { throw "Cannot resolve the current Windows user profile" }
    return [IO.Path]::GetFullPath($path)
}

function Get-AIChatCodexHome {
    $profile = Get-AIChatUserProfile
    $path = [IO.Path]::GetFullPath((Join-Path $profile ".codex"))
    [void](Assert-AIChatNoReparsePath -Path $path -StopAt $profile)
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) { throw "The current user's fixed CODEX_HOME is not a directory" }
    $ownerSid = Convert-AIChatIdentityReferenceToSid (Get-Acl -LiteralPath $path).Owner
    if ($ownerSid -ne (Get-AIChatCurrentSid)) {
        throw "The fixed CODEX_HOME must be owned by the current Windows SID"
    }
    return $path
}

function Get-AIChatConnectorDataRoot {
    return [IO.Path]::GetFullPath((Join-Path (Get-AIChatUserProfile) ".aichat\codex-connector"))
}

function Get-AIChatConnectorMappingDigest {
    param([Parameter(Mandatory = $true)]$Settings)

    # Keep this namespace entirely derived from trusted local mapping settings.
    # Relay messages never participate in path selection. The driver and host
    # labels are explicit so future packaged drivers cannot alias this state.
    $canonical = "aichat-windows-mapping-v1`0app-server`0local-agent`0" +
        [string]$Settings.expected_agent_id + "`0" +
        [string]$Settings.channel_id + "`0" + [string]$Settings.target_thread_id
    return Get-AIChatSha256Text -Value $canonical
}

function New-AIChatConnectorMappingState {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        $PreviousSettings,
        $PreviousMappingState
    )

    $digest = Get-AIChatConnectorMappingDigest -Settings $Settings
    $stateBasename = "state-$digest.json"
    $mode = "mapping-digest"
    if ($null -ne $PreviousSettings -and
        (Get-AIChatConnectorMappingDigest -Settings $PreviousSettings) -eq $digest) {
        if ($null -eq $PreviousMappingState) {
            # An installation made before mapping-state.json used state.json.
            # Preserve that exact default for an unchanged mapping; do not move,
            # copy, delete, or silently adopt it for a different mapping.
            $stateBasename = "state.json"
            $mode = "legacy-default"
        } else {
            $stateBasename = [string]$PreviousMappingState.state_basename
            $mode = [string]$PreviousMappingState.state_mode
        }
    }
    return [pscustomobject][ordered]@{
        schema_version = 1
        kind = "aichat-windows-connector-mapping-state"
        mapping_digest = $digest
        driver = "app-server"
        host_binding = "local"
        state_mode = $mode
        state_basename = $stateBasename
    }
}

function Assert-AIChatConnectorMappingState {
    param(
        [Parameter(Mandatory = $true)]$MappingState,
        [Parameter(Mandatory = $true)]$Settings
    )

    $supported = @(
        "schema_version", "kind", "mapping_digest", "driver",
        "host_binding", "state_mode", "state_basename"
    )
    foreach ($name in @($MappingState.PSObject.Properties.Name)) {
        if ($supported -notcontains $name) {
            throw "Windows connector mapping state contains an unsupported field"
        }
    }
    foreach ($required in $supported) {
        if (-not $MappingState.PSObject.Properties[$required]) {
            throw "Windows connector mapping state is incomplete"
        }
    }
    $digest = Get-AIChatConnectorMappingDigest -Settings $Settings
    if ([int]$MappingState.schema_version -ne 1 -or
        [string]$MappingState.kind -ne "aichat-windows-connector-mapping-state" -or
        [string]$MappingState.mapping_digest -notmatch '^[a-f0-9]{64}$' -or
        [string]$MappingState.mapping_digest -ne $digest -or
        [string]$MappingState.driver -ne "app-server" -or
        [string]$MappingState.host_binding -ne "local") {
        throw "Windows connector mapping state does not match the fixed local mapping"
    }
    $expectedBasename = "state-$digest.json"
    if ([string]$MappingState.state_mode -eq "legacy-default") {
        if ([string]$MappingState.state_basename -ne "state.json") {
            throw "Legacy connector mapping state must retain state.json"
        }
    } elseif ([string]$MappingState.state_mode -eq "mapping-digest") {
        if ([string]$MappingState.state_basename -ne $expectedBasename) {
            throw "Digest connector mapping state basename is invalid"
        }
    } else {
        throw "Windows connector mapping state mode is invalid"
    }
    return $MappingState
}

function Get-AIChatConnectorStatePath {
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)]$MappingState
    )

    [void](Assert-AIChatConnectorMappingState `
        -MappingState $MappingState `
        -Settings $Settings)
    $path = Join-Path $Paths.ConnectorDataRoot ([string]$MappingState.state_basename)
    $resolved = Assert-AIChatPathWithinRoot -Path $path -Root $Paths.ConnectorDataRoot
    if ((Split-Path -Leaf $resolved) -ne [string]$MappingState.state_basename) {
        throw "Connector mapping state path must be a direct child of the data root"
    }
    return $resolved
}

function Assert-AIChatSupervisedResultEgressCheckpoint {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)]$ConnectorReceipt,
        [Parameter(Mandatory = $true)]$DriverRecord
    )

    if (-not [bool]$Settings.egress.enabled) { return $false }

    $outboundMessageId = [Guid]::Empty
    if ($null -eq $DriverRecord.outboundEvent -or
        -not [bool]$DriverRecord.outboundEvent.modelDeclared -or
        [string]$DriverRecord.outboundEvent.messageType -ne "result" -or
        -not [string]$DriverRecord.outboundEvent.eventId -or
        [string]$DriverRecord.outboundEvent.eventId -ne
            [string]$ConnectorReceipt.outbound_event_id -or
        -not [Guid]::TryParseExact(
            [string]$ConnectorReceipt.outbound_message_id,
            "D",
            [ref]$outboundMessageId
        )) {
        throw "Supervised result egress did not persist the matching Relay result"
    }
    return $true
}

function Assert-AIChatNoControlText {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($Value.Contains([char]0) -or $Value.Contains("`r") -or $Value.Contains("`n")) {
        throw "$Name must not contain NUL or line-break characters"
    }
}

function Assert-AIChatPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    $volumeRoot = [IO.Path]::GetPathRoot($resolvedRoot)
    if (-not $resolvedRoot.Equals($volumeRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $resolvedRoot = $resolvedRoot.TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        )
    }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $prefix = if ($resolvedRoot.EndsWith([string][IO.Path]::DirectorySeparatorChar)) {
        $resolvedRoot
    } else {
        $resolvedRoot + [IO.Path]::DirectorySeparatorChar
    }
    if (-not $resolvedPath.Equals($resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -and
        -not $resolvedPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "AIChat private paths must remain below $resolvedRoot"
    }
    return $resolvedPath
}

function Assert-AIChatNoReparsePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StopAt,
        [switch]$LeafMayBeMissing
    )
    $resolved = [IO.Path]::GetFullPath($Path)
    if ($resolved.StartsWith("\\")) {
        throw "UNC paths are not allowed for AIChat protected files"
    }
    $stop = [IO.Path]::GetPathRoot($resolved)
    if (-not $stop) { throw "AIChat protected path must have a local volume root" }
    [void](Assert-AIChatPathWithinRoot -Path $resolved -Root ([IO.Path]::GetFullPath($StopAt)))

    $relative = $resolved.Substring($stop.Length).TrimStart(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $segments = @(if ($relative) { $relative -split '[\\/]' })
    $current = $stop
    $stopItem = Get-Item -LiteralPath $stop -Force -ErrorAction Stop
    if (-not $stopItem.PSIsContainer -or
        ($stopItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "AIChat path anchor must be a regular directory without a reparse point"
    }
    $missingTail = $false
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $current = Join-Path $current $segments[$index]
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            if ($LeafMayBeMissing) {
                $missingTail = $true
                continue
            }
            throw "AIChat path component does not exist: $current"
        }
        if ($missingTail) {
            throw "AIChat protected path contains an object below a missing ancestor"
        }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "AIChat protected paths must not contain reparse points"
        }
    }
    return $resolved
}

function Convert-AIChatIdentityReferenceToSid {
    param([Parameter(Mandatory = $true)]$IdentityReference)
    try {
        return $IdentityReference.Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
    } catch {
        return ([Security.Principal.NTAccount]::new([string]$IdentityReference)).Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
    }
}

function Initialize-AIChatOwnerDaclNative {
    if (-not ("AIChat.Windows.OwnerDacl" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;

namespace AIChat.Windows {
    public static class OwnerDacl {
        private const uint SE_FILE_OBJECT = 1;
        private const uint OWNER_SECURITY_INFORMATION = 0x00000001;
        private const uint DACL_SECURITY_INFORMATION = 0x00000004;
        private const uint UNPROTECTED_DACL_SECURITY_INFORMATION = 0x20000000;
        private const uint PROTECTED_DACL_SECURITY_INFORMATION = 0x80000000;
        private const string LOCAL_SYSTEM_SID = "S-1-5-18";

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint SetNamedSecurityInfo(
            string objectName,
            uint objectType,
            uint securityInformation,
            IntPtr owner,
            IntPtr group,
            IntPtr dacl,
            IntPtr sacl
        );

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool GetSecurityDescriptorOwner(
            IntPtr securityDescriptor,
            out IntPtr owner,
            out bool ownerDefaulted
        );

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool GetSecurityDescriptorDacl(
            IntPtr securityDescriptor,
            out bool daclPresent,
            out IntPtr dacl,
            out bool daclDefaulted
        );

        private static SecurityIdentifier CurrentSid() {
            SecurityIdentifier current = WindowsIdentity.GetCurrent().User;
            if (current == null) throw new InvalidOperationException("Current Windows SID is unavailable");
            return current;
        }

        private static void ValidateFixedPrincipals(
            SecurityIdentifier owner,
            SecurityIdentifier[] allowed
        ) {
            SecurityIdentifier current = CurrentSid();
            if (!owner.Equals(current)) {
                throw new InvalidOperationException("AIChat ACL owner must be the current Windows SID");
            }
            bool currentOnly = allowed.Length == 1 && allowed[0].Equals(current);
            bool connectorData = allowed.Length == 2 &&
                ((allowed[0].Equals(current) && allowed[1].Value == LOCAL_SYSTEM_SID) ||
                 (allowed[1].Equals(current) && allowed[0].Value == LOCAL_SYSTEM_SID));
            if (!currentOnly && !connectorData) {
                throw new InvalidOperationException("AIChat ACL principals do not match a fixed private contract");
            }
        }

        private static RawSecurityDescriptor ValidateSnapshot(
            string sddl,
            bool isDirectory
        ) {
            RawSecurityDescriptor descriptor = new RawSecurityDescriptor(sddl);
            if (descriptor.Owner == null || descriptor.DiscretionaryAcl == null ||
                descriptor.SystemAcl != null) {
                throw new InvalidOperationException("AIChat ACL snapshot contains unsupported security sections");
            }
            RawAcl dacl = descriptor.DiscretionaryAcl;
            SecurityIdentifier[] allowed = new SecurityIdentifier[dacl.Count];
            bool isProtected =
                (descriptor.ControlFlags & ControlFlags.DiscretionaryAclProtected) != 0;
            AceFlags inheritanceMask = AceFlags.ContainerInherit | AceFlags.ObjectInherit;
            AceFlags expectedProtectedFlags = isDirectory ? inheritanceMask : AceFlags.None;
            for (int index = 0; index < dacl.Count; index++) {
                CommonAce ace = dacl[index] as CommonAce;
                if (ace == null || ace.IsCallback ||
                    ace.AceQualifier != AceQualifier.AccessAllowed ||
                    ace.AccessMask != (int)FileSystemRights.FullControl) {
                    throw new InvalidOperationException("AIChat ACL snapshot contains an unsupported ACE");
                }
                AceFlags flags = ace.AceFlags;
                if (isProtected) {
                    if (flags != expectedProtectedFlags) {
                        throw new InvalidOperationException("AIChat protected ACL snapshot flags are invalid");
                    }
                } else {
                    AceFlags allowedFlags = inheritanceMask | AceFlags.Inherited;
                    if ((flags & AceFlags.Inherited) == AceFlags.None ||
                        (flags & ~allowedFlags) != AceFlags.None) {
                        throw new InvalidOperationException("AIChat inherited ACL snapshot flags are invalid");
                    }
                }
                allowed[index] = ace.SecurityIdentifier;
            }
            ValidateFixedPrincipals(descriptor.Owner, allowed);
            return descriptor;
        }

        private static void ApplyDescriptor(
            string path,
            RawSecurityDescriptor descriptor,
            uint protectionInformation
        ) {
            byte[] binary = new byte[descriptor.BinaryLength];
            descriptor.GetBinaryForm(binary, 0);
            GCHandle pinned = GCHandle.Alloc(binary, GCHandleType.Pinned);
            try {
                IntPtr pointer = pinned.AddrOfPinnedObject();
                IntPtr ownerPointer;
                bool ownerDefaulted;
                if (!GetSecurityDescriptorOwner(pointer, out ownerPointer, out ownerDefaulted)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                bool daclPresent;
                IntPtr daclPointer;
                bool daclDefaulted;
                if (!GetSecurityDescriptorDacl(
                    pointer,
                    out daclPresent,
                    out daclPointer,
                    out daclDefaulted
                ) || !daclPresent || daclPointer == IntPtr.Zero) {
                    int error = Marshal.GetLastWin32Error();
                    throw new Win32Exception(error == 0 ? 1338 : error);
                }
                uint result = SetNamedSecurityInfo(
                    path,
                    SE_FILE_OBJECT,
                    OWNER_SECURITY_INFORMATION |
                        DACL_SECURITY_INFORMATION |
                        protectionInformation,
                    ownerPointer,
                    IntPtr.Zero,
                    daclPointer,
                    IntPtr.Zero
                );
                if (result != 0) throw new Win32Exception((int)result);
            } finally {
                pinned.Free();
            }
        }

        public static void Apply(
            string path,
            string ownerSidValue,
            string[] allowedSidValues,
            bool isDirectory
        ) {
            SecurityIdentifier owner = new SecurityIdentifier(ownerSidValue);
            SecurityIdentifier[] allowed = new SecurityIdentifier[allowedSidValues.Length];
            RawAcl dacl = new RawAcl(GenericAcl.AclRevision, allowedSidValues.Length);
            AceFlags flags = isDirectory
                ? AceFlags.ContainerInherit | AceFlags.ObjectInherit
                : AceFlags.None;
            for (int index = 0; index < allowedSidValues.Length; index++) {
                SecurityIdentifier sid = new SecurityIdentifier(allowedSidValues[index]);
                allowed[index] = sid;
                dacl.InsertAce(index, new CommonAce(
                    flags,
                    AceQualifier.AccessAllowed,
                    (int)FileSystemRights.FullControl,
                    sid,
                    false,
                    null
                ));
            }
            ValidateFixedPrincipals(owner, allowed);
            RawSecurityDescriptor descriptor = new RawSecurityDescriptor(
                ControlFlags.DiscretionaryAclPresent |
                    ControlFlags.DiscretionaryAclProtected |
                    ControlFlags.SelfRelative,
                owner,
                null,
                null,
                dacl
            );
            ApplyDescriptor(path, descriptor, PROTECTED_DACL_SECURITY_INFORMATION);
        }

        public static void ValidateSnapshotSddl(string sddl, bool isDirectory) {
            ValidateSnapshot(sddl, isDirectory);
        }

        public static void ValidateForwardSnapshotSddl(string sddl, bool isDirectory) {
            RawSecurityDescriptor descriptor = ValidateSnapshot(sddl, isDirectory);
            if ((descriptor.ControlFlags & ControlFlags.DiscretionaryAclProtected) == 0) {
                throw new InvalidOperationException("AIChat forward ACL snapshot must be protected");
            }
            RawAcl dacl = descriptor.DiscretionaryAcl;
            SecurityIdentifier current = CurrentSid();
            bool hasCurrent = false;
            bool hasLocalSystem = false;
            if (dacl.Count != 2) {
                throw new InvalidOperationException("AIChat forward ACL snapshot must contain two fixed principals");
            }
            for (int index = 0; index < dacl.Count; index++) {
                CommonAce ace = (CommonAce)dacl[index];
                if (ace.SecurityIdentifier.Equals(current)) {
                    if (hasCurrent) {
                        throw new InvalidOperationException("AIChat forward ACL snapshot duplicates the current SID");
                    }
                    hasCurrent = true;
                } else if (ace.SecurityIdentifier.Value == LOCAL_SYSTEM_SID) {
                    if (hasLocalSystem) {
                        throw new InvalidOperationException("AIChat forward ACL snapshot duplicates LocalSystem");
                    }
                    hasLocalSystem = true;
                }
            }
            if (!hasCurrent || !hasLocalSystem) {
                throw new InvalidOperationException("AIChat forward ACL snapshot principals are invalid");
            }
        }

        public static bool SnapshotSddlEquivalent(
            string leftSddl,
            string rightSddl,
            bool isDirectory
        ) {
            RawSecurityDescriptor left = ValidateSnapshot(leftSddl, isDirectory);
            RawSecurityDescriptor right = ValidateSnapshot(rightSddl, isDirectory);
            if (!left.Owner.Equals(right.Owner)) return false;
            bool leftProtected =
                (left.ControlFlags & ControlFlags.DiscretionaryAclProtected) != 0;
            bool rightProtected =
                (right.ControlFlags & ControlFlags.DiscretionaryAclProtected) != 0;
            if (leftProtected != rightProtected) return false;

            RawAcl leftDacl = left.DiscretionaryAcl;
            RawAcl rightDacl = right.DiscretionaryAcl;
            if (leftDacl.Count != rightDacl.Count) return false;
            bool[] matched = new bool[rightDacl.Count];
            for (int leftIndex = 0; leftIndex < leftDacl.Count; leftIndex++) {
                CommonAce leftAce = (CommonAce)leftDacl[leftIndex];
                bool found = false;
                for (int rightIndex = 0; rightIndex < rightDacl.Count; rightIndex++) {
                    if (matched[rightIndex]) continue;
                    CommonAce rightAce = (CommonAce)rightDacl[rightIndex];
                    if (leftAce.SecurityIdentifier.Equals(rightAce.SecurityIdentifier) &&
                        leftAce.AceFlags == rightAce.AceFlags &&
                        leftAce.AceQualifier == rightAce.AceQualifier &&
                        leftAce.AccessMask == rightAce.AccessMask &&
                        leftAce.IsCallback == rightAce.IsCallback) {
                        matched[rightIndex] = true;
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        }

        public static void RestoreSnapshot(string path, string sddl, bool isDirectory) {
            RawSecurityDescriptor descriptor = ValidateSnapshot(sddl, isDirectory);
            uint protectionInformation =
                (descriptor.ControlFlags & ControlFlags.DiscretionaryAclProtected) != 0
                    ? PROTECTED_DACL_SECURITY_INFORMATION
                    : UNPROTECTED_DACL_SECURITY_INFORMATION;
            ApplyDescriptor(path, descriptor, protectionInformation);
        }
    }
}
'@
    }
}

function Set-AIChatOwnerAndDacl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$AllowedSids,
        [Parameter(Mandatory = $true)][bool]$IsDirectory
    )

    $ownerSid = Get-AIChatCurrentSid
    $currentOnly = $AllowedSids.Count -eq 1 -and $AllowedSids[0] -eq $ownerSid
    $connectorData = $AllowedSids.Count -eq 2 -and
        $AllowedSids[0] -eq $ownerSid -and
        $AllowedSids[1] -eq $script:AIChatLocalSystemSid
    if (-not $currentOnly -and -not $connectorData) {
        throw "AIChat owner/DACL updates accept only the fixed private ACL contracts"
    }
    Initialize-AIChatOwnerDaclNative

    [AIChat.Windows.OwnerDacl]::Apply(
        [IO.Path]::GetFullPath($Path),
        $ownerSid,
        $AllowedSids,
        $IsDirectory
    )
}

function Assert-AIChatCurrentSidOnlyAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sid = Get-AIChatCurrentSid
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "AIChat private paths must not be reparse points: $Path"
    }
    $acl = Get-Acl -LiteralPath $Path
    $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($ownerSid -ne $sid) {
        throw "AIChat private path owner must be the current Windows SID: $Path"
    }
    $rules = @($acl.GetAccessRules(
        $true,
        $true,
        [Security.Principal.SecurityIdentifier]
    ))
    if (-not $acl.AreAccessRulesProtected -or $rules.Count -ne 1) {
        throw "AIChat private path must have exactly one current-SID ACL rule: $Path"
    }
    $rule = $rules[0]
    $ruleSid = $rule.IdentityReference.Value
    $fullControl = [Security.AccessControl.FileSystemRights]::FullControl
    $expectedInheritance = if ($item.PSIsContainer) {
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
        [Security.AccessControl.InheritanceFlags]::None
    }
    if ($ruleSid -ne $sid -or
        $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        $rule.FileSystemRights -ne $fullControl -or
        $rule.InheritanceFlags -ne $expectedInheritance -or
        $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None -or
        $rule.IsInherited) {
        throw "AIChat private path ACL must grant only non-inherited FullControl to the current SID: $Path"
    }
}

function Get-AIChatHardLinkCount {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not ("AIChat.Windows.NativeFileInformation" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace AIChat.Windows {
    [StructLayout(LayoutKind.Sequential)]
    public struct ByHandleFileInformation {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    public static class NativeFileInformation {
        private const uint FILE_READ_ATTRIBUTES = 0x80;
        private const uint FILE_SHARE_READ = 0x1;
        private const uint FILE_SHARE_WRITE = 0x2;
        private const uint FILE_SHARE_DELETE = 0x4;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle handle,
            out ByHandleFileInformation information
        );

        public static uint GetLinkCount(string path) {
            using (SafeFileHandle handle = CreateFileW(
                path,
                FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                IntPtr.Zero,
                OPEN_EXISTING,
                FILE_FLAG_OPEN_REPARSE_POINT,
                IntPtr.Zero
            )) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(handle, out information)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                return information.NumberOfLinks;
            }
        }
    }
}
'@
    }
    try {
        return [int][AIChat.Windows.NativeFileInformation]::GetLinkCount(
            [IO.Path]::GetFullPath($Path)
        )
    } catch {
        throw "Cannot verify hardlink aliases for AIChat private file: $Path"
    }
}

function Set-AIChatCurrentSidOnlyAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to protect a reparse point: $Path"
    }
    if (-not $item.PSIsContainer -and (Get-AIChatHardLinkCount -Path $Path) -ne 1) {
        throw "Refusing to protect a file with hardlink aliases: $Path"
    }
    Set-AIChatOwnerAndDacl `
        -Path $Path `
        -AllowedSids @($identity.User.Value) `
        -IsDirectory $item.PSIsContainer
    Assert-AIChatCurrentSidOnlyAcl -Path $Path
    if (-not $item.PSIsContainer -and (Get-AIChatHardLinkCount -Path $Path) -ne 1) {
        throw "AIChat private file acquired a hardlink alias while applying ACLs: $Path"
    }
}

function Assert-AIChatConnectorDataAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowLegacyCurrentSidOnly
    )

    $currentSid = Get-AIChatCurrentSid
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Connector state/receipt paths must not be reparse points: $Path"
    }
    if (-not $item.PSIsContainer -and (Get-AIChatHardLinkCount -Path $Path) -ne 1) {
        throw "Connector state/receipt files must not have hardlink aliases: $Path"
    }

    $acl = Get-Acl -LiteralPath $Path
    $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($ownerSid -ne $currentSid) {
        throw "Connector state/receipt path owner must be the current Windows SID: $Path"
    }
    $rules = @($acl.GetAccessRules(
        $true,
        $true,
        [Security.Principal.SecurityIdentifier]
    ))
    $expectedSids = @($currentSid, $script:AIChatLocalSystemSid)
    $actualSids = @($rules | ForEach-Object { $_.IdentityReference.Value })
    $legacyCurrentSidOnly = $AllowLegacyCurrentSidOnly -and
        $rules.Count -eq 1 -and
        $actualSids[0] -eq $currentSid
    $trustedPair = $rules.Count -eq 2 -and
        @($expectedSids | Where-Object { $actualSids -notcontains $_ }).Count -eq 0
    $migratableInherited = $AllowLegacyCurrentSidOnly -and
        -not $acl.AreAccessRulesProtected -and
        ($legacyCurrentSidOnly -or $trustedPair) -and
        @($rules | Where-Object { -not $_.IsInherited }).Count -eq 0
    if (-not $legacyCurrentSidOnly -and -not $trustedPair) {
        throw "Connector state/receipt ACL contains an untrusted or missing principal: $Path"
    }
    if (-not $acl.AreAccessRulesProtected -and -not $migratableInherited) {
        throw "Connector state/receipt ACL inheritance is not protected: $Path"
    }

    $fullControl = [Security.AccessControl.FileSystemRights]::FullControl
    $expectedInheritance = if ($item.PSIsContainer) {
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
        [Security.AccessControl.InheritanceFlags]::None
    }
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.FileSystemRights -ne $fullControl -or
            $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None) {
            throw "Connector state/receipt ACL grants unexpected rights: $Path"
        }
        if ($migratableInherited) { continue }
        if ($rule.IsInherited -or $rule.InheritanceFlags -ne $expectedInheritance) {
            throw "Connector state/receipt ACL inheritance contract is invalid: $Path"
        }
    }
}

function Set-AIChatConnectorDataAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to protect a connector state/receipt reparse point: $Path"
    }
    if (-not $item.PSIsContainer -and (Get-AIChatHardLinkCount -Path $Path) -ne 1) {
        throw "Refusing to protect a connector state/receipt file with hardlink aliases: $Path"
    }
    Set-AIChatOwnerAndDacl `
        -Path $Path `
        -AllowedSids @($identity.User.Value, $script:AIChatLocalSystemSid) `
        -IsDirectory $item.PSIsContainer
    Assert-AIChatConnectorDataAcl -Path $Path
}

function Get-AIChatOwnerAndDaclSddl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $acl = Get-Acl -LiteralPath $Path
    $sections = [Security.AccessControl.AccessControlSections]::Owner -bor
        [Security.AccessControl.AccessControlSections]::Access
    return $acl.GetSecurityDescriptorSddlForm($sections)
}

function Assert-AIChatConnectorDataAclSnapshot {
    param([Parameter(Mandatory = $true)]$Snapshot)

    if (-not $Snapshot.PSObject.Properties["schema_version"] -or
        [int]$Snapshot.schema_version -ne 1 -or
        -not $Snapshot.PSObject.Properties["existed"] -or
        -not $Snapshot.PSObject.Properties["private_root_existed"] -or
        -not $Snapshot.PSObject.Properties["entries"]) {
        throw "Connector data ACL rollback snapshot schema is invalid"
    }
    $entries = @($Snapshot.entries)
    if (-not [bool]$Snapshot.existed) {
        if ($entries.Count -ne 0) {
            throw "Missing connector data root cannot have ACL snapshot entries"
        }
        return
    }
    if (-not [bool]$Snapshot.private_root_existed -or $entries.Count -lt 1) {
        throw "Existing connector data root requires a parent and ACL entries"
    }

    Initialize-AIChatOwnerDaclNative
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        if (-not $entry.PSObject.Properties["name"] -or
            -not $entry.PSObject.Properties["is_directory"] -or
            -not $entry.PSObject.Properties["sddl"] -or
            -not $entry.PSObject.Properties["sddl_sha256"]) {
            throw "Connector data ACL rollback entry schema is invalid"
        }
        $name = [string]$entry.name
        $isRoot = $name -eq "."
        if (-not $isRoot -and
            ($name.Length -eq 0 -or
             [IO.Path]::GetFileName($name) -ne $name -or
             $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0)) {
            throw "Connector data ACL rollback entry name is invalid"
        }
        if (-not $seen.Add($name) -or [bool]$entry.is_directory -ne $isRoot) {
            throw "Connector data ACL rollback entries are duplicated or have an invalid type"
        }
        $sddl = [string]$entry.sddl
        if ((Get-AIChatSha256Text -Value $sddl) -ne
            ([string]$entry.sddl_sha256).ToLowerInvariant()) {
            throw "Connector data ACL rollback entry hash is invalid"
        }
        [AIChat.Windows.OwnerDacl]::ValidateSnapshotSddl($sddl, $isRoot)
    }
    if (-not $seen.Contains(".")) {
        throw "Connector data ACL rollback snapshot is missing the root entry"
    }
}

function Assert-AIChatConnectorDataAclMatchesSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual
    )

    Assert-AIChatConnectorDataAclSnapshot -Snapshot $Expected
    Assert-AIChatConnectorDataAclSnapshot -Snapshot $Actual
    if ([bool]$Expected.existed -ne [bool]$Actual.existed -or
        [bool]$Expected.private_root_existed -ne [bool]$Actual.private_root_existed) {
        throw "Connector data ACL state does not match its rollback snapshot"
    }
    Initialize-AIChatOwnerDaclNative
    $expectedEntries = @($Expected.entries)
    $actualEntries = @($Actual.entries)
    if ($expectedEntries.Count -ne $actualEntries.Count) {
        throw "Connector data ACL entry count does not match its rollback snapshot"
    }
    foreach ($expectedEntry in $expectedEntries) {
        $matches = @($actualEntries | Where-Object {
            [string]$_.name -ceq [string]$expectedEntry.name
        })
        if ($matches.Count -ne 1 -or
            [bool]$matches[0].is_directory -ne [bool]$expectedEntry.is_directory -or
            -not [AIChat.Windows.OwnerDacl]::SnapshotSddlEquivalent(
                [string]$expectedEntry.sddl,
                [string]$matches[0].sddl,
                [bool]$expectedEntry.is_directory
            )) {
            throw "Connector data owner/DACL does not match its rollback snapshot"
        }
    }
}

function Assert-AIChatConnectorDataAclRepairEligible {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual
    )

    # The expected journal snapshot is validated by the narrow native parser:
    # current owner, FullControl allow ACEs, and only the current SID or the
    # current SID plus LocalSystem. It may retain the explicitly supported
    # inherited historical form. Each live entry must be either already at the
    # exact journal target or at the protected current-SID plus LocalSystem
    # forward contract. This makes a hard-interrupted prefix safely resumable.
    Assert-AIChatConnectorDataAclSnapshot -Snapshot $Expected
    Assert-AIChatConnectorDataAclSnapshot -Snapshot $Actual
    if (-not [bool]$Expected.existed -or -not [bool]$Actual.existed -or
        -not [bool]$Expected.private_root_existed -or
        -not [bool]$Actual.private_root_existed) {
        throw "Connector data ACL repair requires an existing unchanged data tree"
    }

    $expectedEntries = @($Expected.entries)
    $actualEntries = @($Actual.entries)
    if ($expectedEntries.Count -ne $actualEntries.Count) {
        throw "Connector data ACL repair requires the exact journal entry set"
    }
    Initialize-AIChatOwnerDaclNative
    $forwardEntryCount = 0
    foreach ($actualEntry in $actualEntries) {
        $expectedMatches = @($expectedEntries | Where-Object {
            [string]$_.name -ceq [string]$actualEntry.name
        })
        if ($expectedMatches.Count -ne 1 -or
            [bool]$expectedMatches[0].is_directory -ne [bool]$actualEntry.is_directory) {
            throw "Connector data ACL repair requires the exact journal entry types"
        }
        $alreadyAtTarget = [AIChat.Windows.OwnerDacl]::SnapshotSddlEquivalent(
            [string]$expectedMatches[0].sddl,
            [string]$actualEntry.sddl,
            [bool]$actualEntry.is_directory
        )
        if (-not $alreadyAtTarget) {
            [AIChat.Windows.OwnerDacl]::ValidateForwardSnapshotSddl(
                [string]$actualEntry.sddl,
                [bool]$actualEntry.is_directory
            )
            $forwardEntryCount += 1
        }
    }

    $alreadyExact = $true
    try {
        Assert-AIChatConnectorDataAclMatchesSnapshot `
            -Expected $Expected `
            -Actual $Actual
    } catch {
        $alreadyExact = $false
    }
    if ($alreadyExact) {
        throw "Connector data ACL already matches its rollback snapshot"
    }
    if ($forwardEntryCount -lt 1) {
        throw "Connector data ACL repair requires at least one trusted forward entry"
    }

    return [pscustomobject][ordered]@{
        entry_set_exact = $true
        current_acl_transition_trusted = $true
        forward_entry_count = $forwardEntryCount
        journal_acl_snapshot_trusted = $true
        connector_data_acl_exact = $false
    }
}

function Assert-AIChatConnectorDataAclTransitionState {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][object[]]$AllowedSnapshots
    )

    if ($AllowedSnapshots.Count -ne 2) {
        throw "Connector data ACL transition requires exactly two fixed snapshots"
    }
    Assert-AIChatConnectorDataAclSnapshot -Snapshot $Actual
    foreach ($snapshot in $AllowedSnapshots) {
        Assert-AIChatConnectorDataAclSnapshot -Snapshot $snapshot
        if (-not [bool]$snapshot.existed -or
            -not [bool]$snapshot.private_root_existed) {
            throw "Connector data ACL transition snapshots must describe an existing tree"
        }
    }
    if (-not [bool]$Actual.existed -or
        -not [bool]$Actual.private_root_existed) {
        throw "Connector data ACL transition state must retain the existing tree"
    }

    Initialize-AIChatOwnerDaclNative
    $actualEntries = @($Actual.entries)
    $referenceEntries = @($AllowedSnapshots[0].entries)
    if ($actualEntries.Count -ne $referenceEntries.Count) {
        throw "Connector data ACL transition changed the entry set"
    }
    foreach ($snapshot in $AllowedSnapshots) {
        if (@($snapshot.entries).Count -ne $referenceEntries.Count) {
            throw "Connector data ACL transition snapshots do not share an exact entry count"
        }
    }
    foreach ($actualEntry in $actualEntries) {
        $referenceMatches = @($referenceEntries | Where-Object {
            [string]$_.name -ceq [string]$actualEntry.name
        })
        if ($referenceMatches.Count -ne 1 -or
            [bool]$referenceMatches[0].is_directory -ne [bool]$actualEntry.is_directory) {
            throw "Connector data ACL transition changed an entry type"
        }
        $allowedExact = $false
        foreach ($snapshot in $AllowedSnapshots) {
            $matches = @($snapshot.entries | Where-Object {
                [string]$_.name -ceq [string]$actualEntry.name
            })
            if ($matches.Count -ne 1 -or
                [bool]$matches[0].is_directory -ne [bool]$actualEntry.is_directory) {
                throw "Connector data ACL transition snapshots do not share an exact entry set"
            }
            if ([AIChat.Windows.OwnerDacl]::SnapshotSddlEquivalent(
                [string]$matches[0].sddl,
                [string]$actualEntry.sddl,
                [bool]$actualEntry.is_directory
            )) {
                $allowedExact = $true
            }
        }
        if (-not $allowedExact) {
            throw "Connector data ACL transition contains an ACL outside the two fixed snapshots"
        }
    }
}

function Get-AIChatConnectorDataContentSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $profile = Get-AIChatUserProfile
    $privateRoot = Join-Path $profile ".aichat"
    $target = Assert-AIChatPathWithinRoot -Path $Path -Root $privateRoot
    if (-not $target.Equals((Get-AIChatConnectorDataRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Connector data content snapshot must use the fixed user-profile path"
    }
    [void](Assert-AIChatNoReparsePath -Path $target -StopAt $profile)
    $root = Get-Item -LiteralPath $target -Force -ErrorAction Stop
    if (-not $root.PSIsContainer) {
        throw "Connector data content snapshot target must be a directory"
    }

    $entries = [Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $target -Force | Sort-Object Name)) {
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            (Get-AIChatHardLinkCount -Path $item.FullName) -ne 1) {
            throw "Connector data content snapshot accepts only regular unaliased files"
        }
        $entries.Add([pscustomobject][ordered]@{
            name = [string]$item.Name
            length = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
    return [pscustomobject][ordered]@{
        entries = @($entries)
    }
}

function Assert-AIChatConnectorDataContentMatchesSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual
    )

    $expectedEntries = @($Expected.entries)
    $actualEntries = @($Actual.entries)
    if ($expectedEntries.Count -ne $actualEntries.Count) {
        throw "Connector data content changed during ACL repair"
    }
    foreach ($expectedEntry in $expectedEntries) {
        $matches = @($actualEntries | Where-Object {
            [string]$_.name -ceq [string]$expectedEntry.name
        })
        if ($matches.Count -ne 1 -or
            [long]$matches[0].length -ne [long]$expectedEntry.length -or
            [string]$matches[0].sha256 -cne [string]$expectedEntry.sha256) {
            throw "Connector data content changed during ACL repair"
        }
    }
}

function Get-AIChatConnectorDataAclSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $profile = Get-AIChatUserProfile
    $privateRoot = Join-Path $profile ".aichat"
    $target = Assert-AIChatPathWithinRoot -Path $Path -Root $privateRoot
    if (-not $target.Equals((Get-AIChatConnectorDataRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Connector data ACL snapshot must use the fixed user-profile path"
    }
    [void](Assert-AIChatNoReparsePath -Path $target -StopAt $profile -LeafMayBeMissing)

    $privateRootItem = Get-Item -LiteralPath $privateRoot -Force -ErrorAction SilentlyContinue
    if ($null -ne $privateRootItem) {
        if (-not $privateRootItem.PSIsContainer) {
            throw "Connector data private root is occupied by a file"
        }
        [void](Assert-AIChatPrivateDirectoryTree -Path $privateRoot -ProtectedRoot $privateRoot)
    }
    $existing = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        return [pscustomobject][ordered]@{
            schema_version = 1
            existed = $false
            private_root_existed = $null -ne $privateRootItem
            entries = @()
        }
    }
    if (-not $existing.PSIsContainer) {
        throw "Connector data ACL snapshot target is occupied by a file"
    }
    Assert-AIChatConnectorDataAcl -Path $target -AllowLegacyCurrentSidOnly
    $items = @(Get-ChildItem -LiteralPath $target -Force | Sort-Object Name)
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($item in @($existing) + $items) {
        if ($item -ne $existing) {
            if ($item.PSIsContainer) {
                throw "Connector data ACL snapshot does not accept subdirectories"
            }
            Assert-AIChatConnectorDataAcl -Path $item.FullName -AllowLegacyCurrentSidOnly
        }
        $name = if ($item -eq $existing) { "." } else { [string]$item.Name }
        $sddl = Get-AIChatOwnerAndDaclSddl -Path $item.FullName
        $entries.Add([pscustomobject][ordered]@{
            name = $name
            is_directory = [bool]$item.PSIsContainer
            sddl = $sddl
            sddl_sha256 = Get-AIChatSha256Text -Value $sddl
        })
    }
    $snapshot = [pscustomobject][ordered]@{
        schema_version = 1
        existed = $true
        private_root_existed = $true
        entries = @($entries)
    }
    Assert-AIChatConnectorDataAclSnapshot -Snapshot $snapshot
    return $snapshot
}

function Restore-AIChatConnectorDataAclSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Path,
        [object[]]$AllowedTransitionSnapshots = @()
    )

    Assert-AIChatConnectorDataAclSnapshot -Snapshot $Snapshot
    $profile = Get-AIChatUserProfile
    $privateRoot = Join-Path $profile ".aichat"
    $target = Assert-AIChatPathWithinRoot -Path $Path -Root $privateRoot
    if (-not $target.Equals((Get-AIChatConnectorDataRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Connector data ACL rollback must use the fixed user-profile path"
    }

    if (-not [bool]$Snapshot.existed) {
        if (Test-Path -LiteralPath $target) {
            [void](Assert-AIChatConnectorDataTree -Path $target)
            if (@(Get-ChildItem -LiteralPath $target -Force).Count -ne 0) {
                throw "Refusing to remove a connector data root that acquired runtime files"
            }
            Remove-Item -LiteralPath $target -Force
        }
        if (-not [bool]$Snapshot.private_root_existed -and
            (Test-Path -LiteralPath $privateRoot -PathType Container)) {
            [void](Assert-AIChatPrivateDirectoryTree -Path $privateRoot -ProtectedRoot $privateRoot)
            if (@(Get-ChildItem -LiteralPath $privateRoot -Force).Count -ne 0) {
                throw "Refusing to remove a connector private root that acquired other files"
            }
            Remove-Item -LiteralPath $privateRoot -Force
        }
        return
    }

    if ($AllowedTransitionSnapshots.Count -gt 0) {
        $targetAllowed = $false
        foreach ($allowedSnapshot in $AllowedTransitionSnapshots) {
            try {
                Assert-AIChatConnectorDataAclMatchesSnapshot `
                    -Expected $allowedSnapshot `
                    -Actual $Snapshot
                $targetAllowed = $true
            } catch {
                # Continue only across the fixed transition snapshot pair.
            }
        }
        if (-not $targetAllowed) {
            throw "Connector data ACL transition target is outside the two fixed snapshots"
        }
        $transitionState = Get-AIChatConnectorDataAclSnapshot -Path $target
        Assert-AIChatConnectorDataAclTransitionState `
            -Actual $transitionState `
            -AllowedSnapshots $AllowedTransitionSnapshots
    } else {
        [void](Assert-AIChatConnectorDataTree -Path $target)
    }
    $expectedFiles = @($Snapshot.entries | Where-Object { [string]$_.name -ne "." })
    $actualFiles = @(Get-ChildItem -LiteralPath $target -Force)
    if ($actualFiles.Count -ne $expectedFiles.Count) {
        throw "Connector data tree changed after its ACL snapshot"
    }
    foreach ($item in $actualFiles) {
        if ($item.PSIsContainer -or
            @($expectedFiles | Where-Object { [string]$_.name -ieq $item.Name }).Count -ne 1) {
            throw "Connector data tree no longer matches its ACL snapshot"
        }
    }

    $rootEntry = @($Snapshot.entries | Where-Object { [string]$_.name -eq "." })[0]
    [AIChat.Windows.OwnerDacl]::RestoreSnapshot(
        $target,
        [string]$rootEntry.sddl,
        $true
    )
    foreach ($entry in $expectedFiles) {
        $entryPath = Join-Path $target ([string]$entry.name)
        [AIChat.Windows.OwnerDacl]::RestoreSnapshot(
            $entryPath,
            [string]$entry.sddl,
            $false
        )
    }
    foreach ($entry in @($rootEntry) + $expectedFiles) {
        $entryPath = if ([string]$entry.name -eq ".") {
            $target
        } else {
            Join-Path $target ([string]$entry.name)
        }
        if (-not [AIChat.Windows.OwnerDacl]::SnapshotSddlEquivalent(
            [string]$entry.sddl,
            (Get-AIChatOwnerAndDaclSddl -Path $entryPath),
            [bool]$entry.is_directory
        )) {
            throw "Connector data ACL rollback did not restore the exact owner/DACL"
        }
    }
}

function Invoke-AIChatConnectorDataAclSnapshotRepair {
    param(
        [Parameter(Mandatory = $true)]$ExpectedSnapshot,
        [Parameter(Mandatory = $true)]$CurrentSnapshot,
        [Parameter(Mandatory = $true)][string]$Path,
        [scriptblock]$PostRepairVerifier,
        [scriptblock]$PostCompensationVerifier,
        [scriptblock]$RestoreInvoker,
        [scriptblock]$SnapshotProvider
    )

    [void](Assert-AIChatConnectorDataAclRepairEligible `
        -Expected $ExpectedSnapshot `
        -Actual $CurrentSnapshot)
    $allowedTransitions = @($CurrentSnapshot, $ExpectedSnapshot)
    $restore = {
        param($TargetSnapshot)
        if ($null -eq $RestoreInvoker) {
            Restore-AIChatConnectorDataAclSnapshot `
                -Snapshot $TargetSnapshot `
                -Path $Path `
                -AllowedTransitionSnapshots $allowedTransitions
        } else {
            & $RestoreInvoker $TargetSnapshot $Path $allowedTransitions
        }
    }
    $readSnapshot = {
        if ($null -eq $SnapshotProvider) {
            return Get-AIChatConnectorDataAclSnapshot -Path $Path
        }
        return & $SnapshotProvider $Path
    }

    try {
        & $restore $ExpectedSnapshot
        $repaired = & $readSnapshot
        Assert-AIChatConnectorDataAclMatchesSnapshot `
            -Expected $ExpectedSnapshot `
            -Actual $repaired
        if ($null -ne $PostRepairVerifier) {
            return & $PostRepairVerifier
        }
        return $repaired
    } catch {
        $primaryMessage = $_.Exception.Message
        try {
            # A failed restore may leave a root or prefix at the journal ACL.
            # The transition allowlist accepts only entries exactly equal to
            # the pre-mutation forward snapshot or the journal target, so the
            # same no-SACL native API can safely converge back to Current.
            & $restore $CurrentSnapshot
            $compensated = & $readSnapshot
            Assert-AIChatConnectorDataAclMatchesSnapshot `
                -Expected $CurrentSnapshot `
                -Actual $compensated
            if ($null -ne $PostCompensationVerifier) {
                [void](& $PostCompensationVerifier)
            }
        } catch {
            $compensationMessage = $_.Exception.Message
            throw "Connector ACL repair failed and pre-repair ACL compensation failed; journal retained; primary_error=$primaryMessage; compensation_error=$compensationMessage"
        }
        throw "Connector ACL repair failed; exact pre-repair ACL restored; journal retained; primary_error=$primaryMessage"
    }
}

function Initialize-AIChatConnectorDataDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $profile = Get-AIChatUserProfile
    $privateRoot = Join-Path $profile ".aichat"
    $target = Assert-AIChatPathWithinRoot -Path $Path -Root $privateRoot
    if (-not $target.Equals((Get-AIChatConnectorDataRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Connector state/receipt directory must use the fixed user-profile path"
    }
    [void](Initialize-AIChatPrivateDirectory `
        -Path $privateRoot `
        -ProtectedRoot $privateRoot `
        -AnchorRoot $profile)
    [void](Assert-AIChatNoReparsePath -Path $target -StopAt $profile -LeafMayBeMissing)

    $existing = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        New-Item -ItemType Directory -Path $target | Out-Null
    } elseif (-not $existing.PSIsContainer) {
        throw "Connector state/receipt path is occupied by a file"
    } else {
        Assert-AIChatConnectorDataAcl -Path $target -AllowLegacyCurrentSidOnly
    }

    $items = @(Get-ChildItem -LiteralPath $target -Force)
    foreach ($item in $items) {
        if ($item.PSIsContainer) {
            throw "Connector state/receipt directory must not contain subdirectories"
        }
        Assert-AIChatConnectorDataAcl -Path $item.FullName -AllowLegacyCurrentSidOnly
    }
    Set-AIChatConnectorDataAcl -Path $target
    foreach ($item in $items) {
        Set-AIChatConnectorDataAcl -Path $item.FullName
    }
    [void](Assert-AIChatConnectorDataTree -Path $target)
    return $target
}

function Initialize-AIChatPrivateDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProtectedRoot,
        [string]$AnchorRoot
    )

    $anchor = if ($AnchorRoot) { [IO.Path]::GetFullPath($AnchorRoot) } else { Get-AIChatLocalAppData }
    $root = Assert-AIChatPathWithinRoot -Path $ProtectedRoot -Root $anchor
    $target = Assert-AIChatPathWithinRoot -Path $Path -Root $root
    [void](Assert-AIChatNoReparsePath -Path $root -StopAt $anchor -LeafMayBeMissing)

    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        New-Item -ItemType Directory -Path $root | Out-Null
        Set-AIChatCurrentSidOnlyAcl -Path $root
    } else {
        Assert-AIChatCurrentSidOnlyAcl -Path $root
    }

    $relative = $target.Substring($root.Length).TrimStart(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $current = $root
    foreach ($segment in @(if ($relative) { $relative -split '[\\/]' })) {
        $current = Join-Path $current $segment
        $existing = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $existing) {
            New-Item -ItemType Directory -Path $current | Out-Null
            Set-AIChatCurrentSidOnlyAcl -Path $current
        } else {
            if (-not $existing.PSIsContainer) {
                throw "AIChat private directory path is occupied by a file: $current"
            }
            Assert-AIChatCurrentSidOnlyAcl -Path $current
        }
    }
    return $target
}

function Assert-AIChatPrivateDirectoryTree {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProtectedRoot
    )
    $root = [IO.Path]::GetFullPath($ProtectedRoot)
    $target = Assert-AIChatPathWithinRoot -Path $Path -Root $root
    [void](Assert-AIChatNoReparsePath -Path $target -StopAt ([IO.Path]::GetPathRoot($target)))
    $relative = $target.Substring($root.Length).TrimStart(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $current = $root
    Assert-AIChatCurrentSidOnlyAcl -Path $current
    foreach ($segment in @(if ($relative) { $relative -split '[\\/]' })) {
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            throw "AIChat private directory tree contains a non-directory: $current"
        }
        Assert-AIChatCurrentSidOnlyAcl -Path $current
    }
    return $target
}

function Assert-AIChatConnectorDataTree {
    param([Parameter(Mandatory = $true)][string]$Path)
    $privateRoot = Join-Path (Get-AIChatUserProfile) ".aichat"
    [void](Assert-AIChatPrivateDirectoryTree -Path $privateRoot -ProtectedRoot $privateRoot)
    $root = Assert-AIChatPathWithinRoot -Path $Path -Root $privateRoot
    if (-not $root.Equals((Get-AIChatConnectorDataRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Connector state/receipt directory must use the fixed user-profile path"
    }
    [void](Assert-AIChatNoReparsePath -Path $root -StopAt (Get-AIChatUserProfile))
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) {
        throw "Connector state/receipt root must be a directory"
    }
    Assert-AIChatConnectorDataAcl -Path $root
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Connector state/receipt directory contains a reparse point"
        }
        if ($item.PSIsContainer) {
            throw "Connector state/receipt directory must not contain subdirectories"
        }
        if ((Get-AIChatHardLinkCount -Path $item.FullName) -ne 1) {
            throw "Connector state/receipt file has a hardlink alias"
        }
        Assert-AIChatConnectorDataAcl -Path $item.FullName
    }
    return $root
}

function Assert-AIChatConnectorDataFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = Get-AIChatConnectorDataRoot
    [void](Assert-AIChatConnectorDataTree -Path $root)
    $resolved = Assert-AIChatPathWithinRoot -Path $Path -Root $root
    [void](Assert-AIChatNoReparsePath -Path $resolved -StopAt $root)
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Connector state/receipt JSON must be a regular non-reparse file: $resolved"
    }
    Assert-AIChatConnectorDataAcl -Path $resolved
    return $resolved
}

function Assert-AIChatPrivateFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProtectedRoot
    )

    $resolved = Assert-AIChatPathWithinRoot -Path $Path -Root $ProtectedRoot
    [void](Assert-AIChatNoReparsePath -Path $resolved -StopAt $ProtectedRoot)
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "AIChat private JSON must be a regular non-reparse file: $resolved"
    }
    Assert-AIChatCurrentSidOnlyAcl -Path $resolved
    if ((Get-AIChatHardLinkCount -Path $resolved) -ne 1) {
        throw "AIChat private files must not have hardlink aliases: $resolved"
    }
    return $resolved
}

function Read-AIChatPrivateJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProtectedRoot
    )

    $resolved = Assert-AIChatPrivateFile -Path $Path -ProtectedRoot $ProtectedRoot
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.FileStream]::new(
            $resolved,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::None
        )
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true)
        $raw = $reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
    if (-not $raw.Trim()) { throw "AIChat private JSON must not be empty: $resolved" }
    $value = $raw | ConvertFrom-Json
    if ($null -eq $value -or $value -isnot [psobject]) {
        throw "AIChat private JSON must contain an object: $resolved"
    }
    return $value
}

function Read-AIChatConnectorDataJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = Assert-AIChatConnectorDataFile -Path $Path
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.FileStream]::new(
            $resolved,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::None
        )
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true)
        $raw = $reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
    if (-not $raw.Trim()) { throw "Connector state/receipt JSON must not be empty: $resolved" }
    $value = $raw | ConvertFrom-Json
    if ($null -eq $value -or $value -isnot [psobject]) {
        throw "Connector state/receipt JSON must contain an object: $resolved"
    }
    return $value
}

function Write-AIChatPrivateJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$ProtectedRoot,
        [int]$Depth = 16
    )

    $resolved = Assert-AIChatPathWithinRoot -Path $Path -Root $ProtectedRoot
    $parent = Split-Path -Parent $resolved
    Assert-AIChatCurrentSidOnlyAcl -Path $parent
    [void](Assert-AIChatNoReparsePath -Path $parent -StopAt $ProtectedRoot)
    $existing = Get-Item -LiteralPath $resolved -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        [void](Assert-AIChatPrivateFile -Path $resolved -ProtectedRoot $ProtectedRoot)
    }

    $temporary = "$resolved.tmp-$([Guid]::NewGuid().ToString('N'))"
    $replacementBackup = "$resolved.bak-$([Guid]::NewGuid().ToString('N'))"
    $stream = $null
    $writer = $null
    try {
        $stream = [IO.FileStream]::new(
            $temporary,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $stream.Dispose()
        $stream = $null
        if ((Get-AIChatHardLinkCount -Path $temporary) -ne 1) {
            throw "Atomic private JSON temporary file has a hardlink alias"
        }
        Set-AIChatCurrentSidOnlyAcl -Path $temporary

        $stream = [IO.FileStream]::new(
            $temporary,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        $writer.Write(($Value | ConvertTo-Json -Depth $Depth) + [Environment]::NewLine)
        $writer.Flush()
        $stream.Flush($true)
        $writer.Dispose()
        $writer = $null
        $stream = $null

        if ($null -ne $existing) {
            [IO.File]::Replace($temporary, $resolved, $replacementBackup)
            if (Test-Path -LiteralPath $replacementBackup) {
                if ((Get-AIChatHardLinkCount -Path $replacementBackup) -ne 1) {
                    throw "Atomic private JSON replacement backup has a hardlink alias"
                }
                Set-AIChatCurrentSidOnlyAcl -Path $replacementBackup
                Remove-Item -LiteralPath $replacementBackup -Force
            }
        } else {
            [IO.File]::Move($temporary, $resolved)
        }
        [void](Assert-AIChatNoReparsePath `
            -Path $resolved `
            -StopAt ([IO.Path]::GetPathRoot($resolved)))
        if ((Get-AIChatHardLinkCount -Path $resolved) -ne 1) {
            throw "Atomic private JSON destination has a hardlink alias"
        }
        Set-AIChatCurrentSidOnlyAcl -Path $resolved
        [void](Assert-AIChatPrivateFile -Path $resolved -ProtectedRoot $ProtectedRoot)
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        foreach ($residue in @($temporary, $replacementBackup)) {
            if (Test-Path -LiteralPath $residue) {
                $residueItem = Get-Item -LiteralPath $residue -Force
                if ($residueItem.PSIsContainer -or
                    ($residueItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                    (Get-AIChatHardLinkCount -Path $residue) -ne 1) {
                    throw "Unsafe atomic private JSON residue requires manual inspection: $residue"
                }
                Set-AIChatCurrentSidOnlyAcl -Path $residue
                Remove-Item -LiteralPath $residue -Force
            }
        }
    }
}

function Test-AIChatForbiddenSettingKey {
    param([Parameter(Mandatory = $true)]$Value)
    $forbidden = @("token", "authorization", "api_key", "access_token", "client_secret")
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string] -and
        $Value -isnot [pscustomobject]) {
        foreach ($item in $Value) {
            if (Test-AIChatForbiddenSettingKey -Value $item) { return $true }
        }
    } elseif ($Value -is [psobject] -and $Value -isnot [string]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($forbidden -contains $property.Name.ToLowerInvariant()) { return $true }
            if (Test-AIChatForbiddenSettingKey -Value $property.Value) { return $true }
        }
    }
    return $false
}

function Get-AIChatRequiredString {
    param($Value, [Parameter(Mandatory = $true)][string]$Name)
    if ($Value -isnot [string] -or -not $Value.Trim()) {
        throw "$Name must be a non-empty string"
    }
    $result = $Value.Trim()
    Assert-AIChatNoControlText -Value $result -Name $Name
    return $result
}

function Get-AIChatValidatedServer {
    param($Value)

    $raw = Get-AIChatRequiredString -Value $Value -Name "identity server"
    try {
        $server = [Uri]$raw
    } catch {
        throw "AIChat identity server URL is invalid"
    }
    if (-not $server.IsAbsoluteUri -or
        $server.Scheme -notin @("http", "https") -or
        -not $server.Host -or
        $server.UserInfo -or $server.Query -or $server.Fragment) {
        throw "AIChat identity server URL is invalid"
    }
    $loopback = $server.Host -in @("localhost", "127.0.0.1", "::1")
    if ($server.Scheme -ne "https" -and -not $loopback) {
        throw "AIChat identity server must use HTTPS outside loopback"
    }
    return $raw.TrimEnd("/")
}

function Test-AIChatRelayIdentity {
    param(
        [Parameter(Mandatory = $true)]$Identity,
        [Parameter(Mandatory = $true)][string]$ExpectedAgentId,
        [scriptblock]$RequestInvoker
    )

    foreach ($required in @("server", "token", "agent_id")) {
        if (-not $Identity.PSObject.Properties[$required] -or
            $Identity.$required -isnot [string] -or
            -not ([string]$Identity.$required).Trim()) {
            throw "AIChat identity config is missing a required field"
        }
    }
    if ([string]$Identity.agent_id -ne $ExpectedAgentId) {
        throw "AIChat identity config does not match the fixed Windows Agent ID"
    }
    $server = Get-AIChatValidatedServer -Value $Identity.server
    $token = [string]$Identity.token
    $remote = if ($null -eq $RequestInvoker) {
        Invoke-RestMethod `
            -Method Get `
            -Uri "$server/v1/me" `
            -Headers @{ Authorization = "Bearer $token" } `
            -TimeoutSec 15 `
            -MaximumRedirection 0
    } else {
        & $RequestInvoker -Uri "$server/v1/me" -Token $token
    }
    if ($null -eq $remote -or
        -not $remote.PSObject.Properties["agent_id"] -or
        [string]$remote.agent_id -ne $ExpectedAgentId) {
        throw "AIChat Relay token is bound to a different Agent ID"
    }
    return $server
}

function Get-AIChatOptionalBoolean {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [bool]$Default = $false
    )
    if ($null -eq $Value) { return $Default }
    if ($Value -isnot [bool]) { throw "$Name must be a boolean" }
    return [bool]$Value
}

function Get-AIChatEgressSettings {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string]$ChannelId,
        [Parameter(Mandatory = $true)][string]$ProtectedRoot
    )

    if ($null -eq $Value) {
        return [pscustomobject][ordered]@{
            enabled = $false
            acknowledged_channel_id = ""
            canary_path = ""
            allowed_reference_hosts = @()
            max_text_bytes = 8192
        }
    }
    if ($Value -isnot [psobject] -or $Value -is [string]) {
        throw "egress must be an object"
    }
    $supported = @(
        "enabled",
        "acknowledged_channel_id",
        "canary_path",
        "allowed_reference_hosts",
        "max_text_bytes"
    )
    foreach ($name in @($Value.PSObject.Properties.Name)) {
        if ($supported -notcontains $name) {
            throw "egress contains unsupported field: $name"
        }
    }

    $enabled = Get-AIChatOptionalBoolean `
        -Value $(if ($Value.PSObject.Properties["enabled"]) { $Value.enabled } else { $null }) `
        -Name "egress.enabled"
    $acknowledgedChannel = if ($Value.PSObject.Properties["acknowledged_channel_id"] -and
        $Value.acknowledged_channel_id -is [string]) {
        ([string]$Value.acknowledged_channel_id).Trim()
    } else { "" }
    $canaryPath = if ($Value.PSObject.Properties["canary_path"] -and
        $Value.canary_path -is [string]) {
        ([string]$Value.canary_path).Trim()
    } else { "" }

    $hostValues = if ($Value.PSObject.Properties["allowed_reference_hosts"]) {
        if ($Value.allowed_reference_hosts -is [string] -or
            $Value.allowed_reference_hosts -isnot [Collections.IEnumerable]) {
            throw "egress.allowed_reference_hosts must be a JSON array"
        }
        @($Value.allowed_reference_hosts)
    } else { @() }
    $hosts = [Collections.Generic.List[string]]::new()
    foreach ($hostValue in $hostValues) {
        $hostName = (Get-AIChatRequiredString `
            -Value $hostValue `
            -Name "egress.allowed_reference_hosts item").ToLowerInvariant()
        $parsedAddress = $null
        if ($hostName -eq "localhost" -or $hostName.Contains(":") -or
            [Net.IPAddress]::TryParse($hostName, [ref]$parsedAddress) -or
            $hostName -notmatch '^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$') {
            throw "egress.allowed_reference_hosts must contain exact public DNS hostnames"
        }
        if (-not $hosts.Contains($hostName)) { $hosts.Add($hostName) }
    }

    $maxTextBytes = if ($Value.PSObject.Properties["max_text_bytes"]) {
        $number = $Value.max_text_bytes
        if ($number -is [bool] -or $number -isnot [ValueType] -or
            [double]$number -ne [Math]::Floor([double]$number)) {
            throw "egress.max_text_bytes must be an integer"
        }
        [int]$number
    } else { 8192 }
    if ($maxTextBytes -lt 128 -or $maxTextBytes -gt 100000) {
        throw "egress.max_text_bytes must be from 128 through 100000"
    }

    if ($enabled) {
        if ($acknowledgedChannel -ne $ChannelId) {
            throw "egress.acknowledged_channel_id must exactly match channel_id"
        }
        if (-not $canaryPath -or -not [IO.Path]::IsPathRooted($canaryPath)) {
            throw "egress.canary_path must be an absolute protected file when egress is enabled"
        }
        $canaryPath = [IO.Path]::GetFullPath($canaryPath)
        [void](Assert-AIChatPrivateFile -Path $canaryPath -ProtectedRoot $ProtectedRoot)
        $stream = $null
        $reader = $null
        try {
            $stream = [IO.FileStream]::new(
                $canaryPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::None
            )
            $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true)
            $canary = $reader.ReadToEnd().Trim()
        } finally {
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
        }
        if ($canary.Length -lt 16 -or $canary.Length -gt 512 -or
            $canary.Contains("`r") -or $canary.Contains("`n")) {
            throw "egress.canary_path must contain one 16 through 512 character canary"
        }
    } elseif ($acknowledgedChannel -or $canaryPath -or $hosts.Count -gt 0) {
        throw "disabled egress must not retain audience, canary, or reference-host settings"
    }

    return [pscustomobject][ordered]@{
        enabled = $enabled
        acknowledged_channel_id = $acknowledgedChannel
        canary_path = $canaryPath
        allowed_reference_hosts = @($hosts)
        max_text_bytes = $maxTextBytes
    }
}

function Resolve-AIChatExecutable {
    param($Value, [Parameter(Mandatory = $true)][string]$Name)
    if ($Value -isnot [string] -or -not $Value.Trim()) {
        throw "$Name must be configured as an absolute executable path"
    }
    $candidate = $Value.Trim()
    if (-not [IO.Path]::IsPathRooted($candidate) -or
        -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "$Name must be an existing absolute executable path"
    }
    $resolved = [IO.Path]::GetFullPath($candidate)
    [void](Assert-AIChatNoReparsePath -Path $resolved -StopAt ([IO.Path]::GetPathRoot($resolved)))
    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "$Name executable must be a regular non-reparse file"
    }
    if (-not $resolved.EndsWith(".exe", [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name must be a native .exe because the connector uses shell=false"
    }
    if ((Get-AIChatHardLinkCount -Path $resolved) -ne 1) {
        throw "$Name executable must not have hardlink aliases"
    }
    $stream = $null
    try {
        $stream = [IO.FileStream]::new(
            $resolved,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        if ($stream.ReadByte() -ne 0x4D -or $stream.ReadByte() -ne 0x5A) {
            throw "$Name must be a native PE executable"
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    return $resolved
}

function Invoke-AIChatNativeVersion {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Argument
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Argument
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Native executable version probe could not start" }
    $stdout = $process.StandardOutput.ReadToEnd()
    [void]$process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = $stdout.Trim()
    }
}

function Get-AIChatConnectorSettings {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProtectedRoot,
        [switch]$RequirePinnedHashes
    )

    $raw = Read-AIChatPrivateJson -Path $Path -ProtectedRoot $ProtectedRoot
    $supported = @(
        "identity_config_path",
        "expected_agent_id",
        "channel_id",
        "allowed_sender_ids",
        "deliver_results",
        "target_thread_id",
        "task_marker",
        "app_server_cwd",
        "sandbox_policy",
        "egress",
        "max_turns_per_sender_per_hour",
        "max_deliveries_per_recovery",
        "node_binary",
        "npm_cli_path",
        "codex_app_server_binary",
        "node_sha256",
        "npm_cli_sha256",
        "codex_sha256"
    )
    foreach ($name in @($raw.PSObject.Properties.Name)) {
        if ($supported -notcontains $name) {
            throw "Windows connector settings contain unsupported field: $name"
        }
    }
    if (Test-AIChatForbiddenSettingKey -Value $raw) {
        throw "Windows connector settings must not contain credentials"
    }

    if (-not $raw.PSObject.Properties["identity_config_path"]) {
        throw "identity_config_path is required"
    }
    $identityPath = [IO.Path]::GetFullPath((Get-AIChatRequiredString `
        -Value $raw.identity_config_path -Name "identity_config_path"))
    [void](Assert-AIChatPrivateFile -Path $identityPath -ProtectedRoot $ProtectedRoot)

    foreach ($requiredName in @("expected_agent_id", "channel_id", "allowed_sender_ids", "target_thread_id", "task_marker", "app_server_cwd", "sandbox_policy")) {
        if (-not $raw.PSObject.Properties[$requiredName]) { throw "$requiredName is required" }
    }
    $expectedAgentId = Get-AIChatRequiredString -Value $raw.expected_agent_id -Name "expected_agent_id"
    $channelId = Get-AIChatRequiredString -Value $raw.channel_id -Name "channel_id"
    $targetThreadId = Get-AIChatRequiredString -Value $raw.target_thread_id -Name "target_thread_id"
    $taskMarker = Get-AIChatRequiredString -Value $raw.task_marker -Name "task_marker"
    if ($taskMarker.Length -lt 16 -or $taskMarker.Length -gt 200) {
        throw "task_marker must contain 16 through 200 characters"
    }
    $egress = Get-AIChatEgressSettings `
        -Value $(if ($raw.PSObject.Properties["egress"]) { $raw.egress } else { $null }) `
        -ChannelId $channelId `
        -ProtectedRoot $ProtectedRoot
    $deliverResults = Get-AIChatOptionalBoolean `
        -Value $(if ($raw.PSObject.Properties["deliver_results"]) { $raw.deliver_results } else { $null }) `
        -Name "deliver_results"

    if ($raw.allowed_sender_ids -is [string] -or
        $raw.allowed_sender_ids -isnot [Collections.IEnumerable]) {
        throw "allowed_sender_ids must be a JSON array"
    }
    $senderValues = @($raw.allowed_sender_ids)
    if ($senderValues.Count -eq 0) {
        throw "allowed_sender_ids must be a non-empty array"
    }
    $senders = [Collections.Generic.List[string]]::new()
    foreach ($value in $senderValues) {
        $sender = Get-AIChatRequiredString -Value $value -Name "allowed_sender_ids item"
        if ($sender -eq "*" -or $sender.Contains(",")) {
            throw "allowed_sender_ids must contain exact IDs without wildcard or comma"
        }
        if (-not $senders.Contains($sender)) { $senders.Add($sender) }
    }

    $cwdValue = Get-AIChatRequiredString -Value $raw.app_server_cwd -Name "app_server_cwd"
    if (-not [IO.Path]::IsPathRooted($cwdValue)) {
        throw "app_server_cwd must be absolute"
    }
    $cwd = [IO.Path]::GetFullPath($cwdValue)
    $cwdRoot = [IO.Path]::GetPathRoot($cwd)
    [void](Assert-AIChatNoReparsePath -Path $cwd -StopAt $cwdRoot)
    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) {
        throw "app_server_cwd must be an existing directory"
    }

    $sandbox = $raw.sandbox_policy
    if ($null -eq $sandbox -or $sandbox -isnot [psobject]) {
        throw "sandbox_policy must be an object"
    }
    foreach ($name in @($sandbox.PSObject.Properties.Name)) {
        if (@("type", "networkAccess", "writableRoots") -notcontains $name) {
            throw "sandbox_policy contains unsupported field: $name"
        }
    }
    $sandboxType = Get-AIChatRequiredString -Value $sandbox.type -Name "sandbox_policy.type"
    if ($sandboxType -notin @("readOnly", "workspaceWrite")) {
        throw "sandbox_policy.type must be readOnly or workspaceWrite"
    }
    if (-not $sandbox.PSObject.Properties["networkAccess"] -or $sandbox.networkAccess -ne $false) {
        throw "sandbox_policy.networkAccess must be false"
    }
    $normalizedSandbox = [ordered]@{
        type = $sandboxType
        networkAccess = $false
    }
    if ($sandboxType -eq "workspaceWrite") {
        $roots = [Collections.Generic.List[string]]::new()
        if (-not $sandbox.PSObject.Properties["writableRoots"]) {
            throw "workspaceWrite requires writableRoots"
        }
        foreach ($value in @($sandbox.writableRoots)) {
            $rootValue = Get-AIChatRequiredString -Value $value -Name "sandbox_policy.writableRoots item"
            if (-not [IO.Path]::IsPathRooted($rootValue)) {
                throw "every writableRoot must be absolute"
            }
            $writeRoot = [IO.Path]::GetFullPath($rootValue)
            $cwdPrefix = $cwd.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $writeRoot.Equals($cwd, [StringComparison]::OrdinalIgnoreCase) -and
                -not $writeRoot.StartsWith($cwdPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "every writableRoot must remain inside app_server_cwd"
            }
            [void](Assert-AIChatNoReparsePath -Path $writeRoot -StopAt ([IO.Path]::GetPathRoot($writeRoot)))
            if (-not (Test-Path -LiteralPath $writeRoot -PathType Container)) {
                throw "every writableRoot must be an existing directory"
            }
            if (-not $roots.Contains($writeRoot)) { $roots.Add($writeRoot) }
        }
        $normalizedSandbox.writableRoots = @($roots)
    }

    $maxTurns = if ($raw.PSObject.Properties["max_turns_per_sender_per_hour"]) {
        $value = $raw.max_turns_per_sender_per_hour
        if ($value -is [bool] -or $value -isnot [ValueType] -or
            [double]$value -ne [Math]::Floor([double]$value)) {
            throw "max_turns_per_sender_per_hour must be an integer"
        }
        [int]$value
    } else { 10 }
    if ($maxTurns -lt 1 -or $maxTurns -gt 1000) {
        throw "max_turns_per_sender_per_hour must be from 1 through 1000"
    }
    $maxDeliveries = if ($raw.PSObject.Properties["max_deliveries_per_recovery"]) {
        $value = $raw.max_deliveries_per_recovery
        if ($value -is [bool] -or $value -isnot [ValueType] -or
            [double]$value -ne [Math]::Floor([double]$value)) {
            throw "max_deliveries_per_recovery must be an integer"
        }
        [int]$value
    } else { 20 }
    if ($maxDeliveries -lt 1 -or $maxDeliveries -gt 200) {
        throw "max_deliveries_per_recovery must be from 1 through 200"
    }

    $nodeValue = if ($raw.PSObject.Properties["node_binary"]) { $raw.node_binary } else { $null }
    $npmValue = if ($raw.PSObject.Properties["npm_cli_path"]) { $raw.npm_cli_path } else { $null }
    $codexValue = if ($raw.PSObject.Properties["codex_app_server_binary"]) { $raw.codex_app_server_binary } else { $null }
    $node = Resolve-AIChatExecutable -Value $nodeValue -Name "node"
    if ($npmValue -isnot [string] -or -not $npmValue.Trim() -or
        -not [IO.Path]::IsPathRooted($npmValue) -or
        -not (Test-Path -LiteralPath $npmValue -PathType Leaf)) {
        throw "npm_cli_path must be an existing absolute npm-cli.js file"
    }
    $npmCli = [IO.Path]::GetFullPath($npmValue.Trim())
    [void](Assert-AIChatNoReparsePath `
        -Path $npmCli `
        -StopAt ([IO.Path]::GetPathRoot($npmCli)))
    $npmItem = Get-Item -LiteralPath $npmCli -Force
    if ($npmItem.PSIsContainer -or
        ($npmItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        (Get-AIChatHardLinkCount -Path $npmCli) -ne 1 -or
        -not $npmCli.EndsWith("npm-cli.js", [StringComparison]::OrdinalIgnoreCase)) {
        throw "npm_cli_path must be one regular non-aliased npm-cli.js file"
    }
    $nodeDirectory = (Split-Path -Parent $node).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $npmCli.StartsWith($nodeDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw "npm_cli_path must remain inside the pinned Node.js installation directory"
    }
    $codex = Resolve-AIChatExecutable -Value $codexValue -Name "codex"
    $nodeHash = (Get-FileHash -LiteralPath $node -Algorithm SHA256).Hash.ToLowerInvariant()
    $npmHash = (Get-FileHash -LiteralPath $npmCli -Algorithm SHA256).Hash.ToLowerInvariant()
    $codexHash = (Get-FileHash -LiteralPath $codex -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($RequirePinnedHashes -and
        (-not $raw.PSObject.Properties["node_sha256"] -or
         -not $raw.PSObject.Properties["npm_cli_sha256"] -or
         -not $raw.PSObject.Properties["codex_sha256"] -or
         [string]$raw.node_sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
         [string]$raw.npm_cli_sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
         [string]$raw.codex_sha256 -notmatch '^[a-fA-F0-9]{64}$')) {
        throw "Installed connector settings require pinned node/npm/codex SHA256 values"
    }
    if ($raw.PSObject.Properties["node_sha256"] -and
        [string]$raw.node_sha256 -ne $nodeHash) {
        throw "node_binary hash does not match the installed settings pin"
    }
    if ($raw.PSObject.Properties["npm_cli_sha256"] -and
        [string]$raw.npm_cli_sha256 -ne $npmHash) {
        throw "npm_cli_path hash does not match the installed settings pin"
    }
    if ($raw.PSObject.Properties["codex_sha256"] -and
        [string]$raw.codex_sha256 -ne $codexHash) {
        throw "codex_app_server_binary hash does not match the installed settings pin"
    }
    $nodeVersion = Invoke-AIChatNativeVersion -FilePath $node -Argument "--version"
    if ($nodeVersion.ExitCode -ne 0 -or $nodeVersion.Output -notmatch '^v(?<major>\d+)\.' -or
        [int]$Matches.major -lt 20) {
        throw "node_binary must provide Node.js 20 or newer"
    }
    $codexVersion = Invoke-AIChatNativeVersion -FilePath $codex -Argument "--version"
    if ($codexVersion.ExitCode -ne 0 -or $codexVersion.Output -notmatch '(?i)codex(?:-cli)?') {
        throw "codex_app_server_binary did not identify itself as the native Codex CLI"
    }
    return [pscustomobject][ordered]@{
        identity_config_path = $identityPath
        expected_agent_id = $expectedAgentId
        channel_id = $channelId
        allowed_sender_ids = @($senders)
        deliver_results = $deliverResults
        target_thread_id = $targetThreadId
        task_marker = $taskMarker
        app_server_cwd = $cwd
        sandbox_policy = [pscustomobject]$normalizedSandbox
        egress = $egress
        max_turns_per_sender_per_hour = $maxTurns
        max_deliveries_per_recovery = $maxDeliveries
        node_binary = $node
        npm_cli_path = $npmCli
        codex_app_server_binary = $codex
        node_sha256 = $nodeHash
        npm_cli_sha256 = $npmHash
        codex_sha256 = $codexHash
    }
}

function Get-AIChatConnectorPaths {
    param(
        [string]$StateRoot
    )

    $taskName = "CodexConnector"
    $taskPath = "\AIChat\"
    $protectedRoot = Get-AIChatProtectedRoot
    $state = if ($StateRoot) {
        Assert-AIChatPathWithinRoot -Path $StateRoot -Root $protectedRoot
    } else {
        Join-Path $protectedRoot "codex-connector-task"
    }
    return [pscustomobject]@{
        ProtectedRoot = $protectedRoot
        StateRoot = [IO.Path]::GetFullPath($state)
        SettingsPath = Join-Path $state "settings.json"
        MappingStatePath = Join-Path $state "mapping-state.json"
        LauncherPath = Join-Path $state "launcher.ps1"
        CommonPath = Join-Path $state "common.ps1"
        ActiveReleasePath = Join-Path $state "active-release.json"
        ReleasesDirectory = Join-Path $state "releases"
        BackupsDirectory = Join-Path $state "backups"
        LastBackupPath = Join-Path $state "last-backup.json"
        TransactionPath = Join-Path $state "transaction.json"
        StagingDirectory = Join-Path $state "staging"
        ConnectorDataRoot = Get-AIChatConnectorDataRoot
        ConnectorLegacyStatePath = Join-Path (Get-AIChatConnectorDataRoot) "state.json"
        TaskName = $taskName
        TaskPath = $taskPath
    }
}

function Get-AIChatTaskDescription {
    return $script:AIChatConnectorTaskDescriptionPrefix + (Get-AIChatCurrentSid)
}

function Test-AIChatTaskSchedulerNotFoundException {
    param([Parameter(Mandatory = $true)][Exception]$Exception)

    $current = $Exception
    while ($null -ne $current) {
        if ([int64]$current.HResult -eq -2147024894) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Get-AIChatConnectorTask {
    if ($env:AICHAT_WINDOWS_CONNECTOR_TEST_TASK_ACCESS -eq "deny") {
        throw "Synthetic Task Scheduler access denial"
    }
    $service = New-Object -ComObject "Schedule.Service"
    $service.Connect()
    try {
        $folder = $service.GetFolder("\AIChat")
    } catch {
        if (-not (Test-AIChatTaskSchedulerNotFoundException -Exception $_.Exception)) {
            throw
        }
        return $null
    }
    try {
        return $folder.GetTask("CodexConnector")
    } catch {
        if (-not (Test-AIChatTaskSchedulerNotFoundException -Exception $_.Exception)) {
            throw
        }
        return $null
    }
}

function Assert-AIChatManagedTask {
    param($Task)
    if ($null -eq $Task) { return }
    if ([string]$Task.Definition.RegistrationInfo.Description -ne (Get-AIChatTaskDescription)) {
        throw "Refusing to replace or remove an unmanaged Scheduled Task"
    }
}

function Assert-AIChatTaskDisabledState {
    param([Parameter(Mandatory = $true)]$Task)
    if ([int]$Task.State -ne 1) {
        throw "Connector Scheduled Task state must be exactly Disabled"
    }
}

function Get-AIChatPowerShellPath {
    $path = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Windows PowerShell 5.1 executable is unavailable"
    }
    return [IO.Path]::GetFullPath($path)
}

function Get-AIChatTaskArguments {
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    if ($StateRoot.Contains('"')) { throw "StateRoot must not contain a double quote" }
    $launcher = Join-Path $StateRoot "launcher.ps1"
    return "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$launcher`" -StateRoot `"$StateRoot`""
}

function Register-AIChatDisabledTask {
    param([Parameter(Mandatory = $true)]$Paths)

    if ($env:AICHAT_WINDOWS_CONNECTOR_TEST_TASK_ACCESS -eq "deny") {
        throw "Synthetic Task Scheduler access denial"
    }
    $sid = Get-AIChatCurrentSid
    $escapedDescription = [Security.SecurityElement]::Escape((Get-AIChatTaskDescription))
    $escapedCommand = [Security.SecurityElement]::Escape((Get-AIChatPowerShellPath))
    $escapedArguments = [Security.SecurityElement]::Escape(
        (Get-AIChatTaskArguments -StateRoot $Paths.StateRoot)
    )
    $escapedWorkingDirectory = [Security.SecurityElement]::Escape($Paths.StateRoot)
    $escapedSid = [Security.SecurityElement]::Escape($sid)
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$escapedDescription</Description></RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>$escapedSid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>false</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$escapedCommand</Command>
      <Arguments>$escapedArguments</Arguments>
      <WorkingDirectory>$escapedWorkingDirectory</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
    $service = New-Object -ComObject "Schedule.Service"
    $service.Connect()
    try {
        $folder = $service.GetFolder("\AIChat")
    } catch {
        if (-not (Test-AIChatTaskSchedulerNotFoundException -Exception $_.Exception)) {
            throw
        }
        $folder = $service.GetFolder("\").CreateFolder("AIChat", $null)
    }
    [void]$folder.RegisterTask("CodexConnector", $xml, 14, $sid, $null, 3, $null)

    $installed = Get-AIChatConnectorTask
    Assert-AIChatManagedTask -Task $installed
    Assert-AIChatTaskContract -Task $installed -Paths $Paths
}

function Get-AIChatTaskPrincipalSid {
    param([Parameter(Mandatory = $true)]$Task)
    return Convert-AIChatIdentityReferenceToSid $Task.Definition.Principal.UserId
}

function Assert-AIChatTaskContract {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)]$Paths
    )
    Assert-AIChatManagedTask -Task $Task
    Assert-AIChatTaskDisabledState -Task $Task
    $definition = $Task.Definition
    if ($Task.Enabled -or $definition.Settings.Enabled) {
        throw "Connector Scheduled Task must be disabled"
    }
    if ($definition.Triggers.Count -ne 0) {
        throw "Connector Scheduled Task must not have triggers"
    }
    if ((Get-AIChatTaskPrincipalSid -Task $Task) -ne (Get-AIChatCurrentSid) -or
        [int]$definition.Principal.LogonType -ne 3 -or
        [int]$definition.Principal.RunLevel -ne 0) {
        throw "Connector Scheduled Task principal contract is invalid"
    }
    if ([int]$definition.Settings.MultipleInstances -ne 2 -or
        -not $definition.Settings.AllowDemandStart) {
        throw "Connector Scheduled Task instance/start contract is invalid"
    }
    if ([string]$definition.Settings.ExecutionTimeLimit -ne "PT0S" -or
        $definition.Settings.Hidden -or
        $definition.Settings.RunOnlyIfIdle -or
        $definition.Settings.WakeToRun -or
        $definition.Settings.DisallowStartIfOnBatteries -or
        $definition.Settings.StopIfGoingOnBatteries -or
        $definition.Settings.StartWhenAvailable -or
        [int]$definition.Settings.RestartCount -ne 0) {
        throw "Connector Scheduled Task execution/power contract is invalid"
    }
    if ($definition.Actions.Count -ne 1) {
        throw "Connector Scheduled Task must contain one action"
    }
    $action = $definition.Actions.Item(1)
    if ([int]$action.Type -ne 0 -or
        -not ([IO.Path]::GetFullPath([string]$action.Path)).Equals(
            (Get-AIChatPowerShellPath),
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        [string]$action.Arguments -ne (Get-AIChatTaskArguments -StateRoot $Paths.StateRoot) -or
        -not ([IO.Path]::GetFullPath([string]$action.WorkingDirectory)).Equals(
            $Paths.StateRoot,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Connector Scheduled Task action contract is invalid"
    }
}

function Assert-AIChatTaskSnapshotForMutation {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)]$Paths,
        [scriptblock]$TaskProvider
    )

    $current = if ($null -eq $TaskProvider) {
        Get-AIChatConnectorTask
    } else {
        & $TaskProvider
    }
    if ([bool]$Snapshot.existed) {
        if ($null -eq $current) {
            throw "Connector Scheduled Task disappeared before mutation"
        }
        Assert-AIChatTaskContract -Task $current -Paths $Paths
        if (-not $Snapshot.PSObject.Properties["xml_sha256"] -or
            (Get-AIChatSha256Text -Value ([string]$current.Xml)) -ne
                ([string]$Snapshot.xml_sha256).ToLowerInvariant()) {
            throw "Connector Scheduled Task changed before mutation"
        }
        return $current
    }
    if ($null -ne $current) {
        throw "Connector Scheduled Task appeared before mutation"
    }
    return $null
}

function Get-AIChatTreeHash {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$RequireCurrentSidOnlyAcl
    )
    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    [void](Assert-AIChatNoReparsePath `
        -Path $resolvedRoot `
        -StopAt ([IO.Path]::GetPathRoot($resolvedRoot)))
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "Tree hash root must be an existing directory"
    }
    if ($RequireCurrentSidOnlyAcl) {
        Assert-AIChatCurrentSidOnlyAcl -Path $resolvedRoot
    }
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse -Force | Sort-Object FullName)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Tree hash refuses reparse points"
        }
        if ($RequireCurrentSidOnlyAcl) {
            Assert-AIChatCurrentSidOnlyAcl -Path $item.FullName
        }
        if ($item.PSIsContainer) { continue }
        if ((Get-AIChatHardLinkCount -Path $item.FullName) -ne 1) {
            throw "Tree hash refuses hardlink aliases"
        }
        $relative = $item.FullName.Substring($resolvedRoot.Length).TrimStart('\', '/').Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines.Add("$relative`t$($item.Length)`t$hash")
    }
    $canonical = (@($lines) -join "`n") + "`n"
    return [pscustomobject]@{
        FileCount = $lines.Count
        Sha256 = Get-AIChatSha256Text -Value $canonical
    }
}

function Get-AIChatSha256Text {
    param([Parameter(Mandatory = $true)][string]$Value)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Copy-AIChatPrivateFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ProtectedRoot
    )
    $sourcePath = [IO.Path]::GetFullPath($Source)
    [void](Assert-AIChatNoReparsePath `
        -Path $sourcePath `
        -StopAt ([IO.Path]::GetPathRoot($sourcePath)))
    $sourceItem = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
    if ($sourceItem.PSIsContainer -or
        ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        (Get-AIChatHardLinkCount -Path $sourcePath) -ne 1) {
        throw "Private file copy source is unsafe: $sourcePath"
    }

    $destinationPath = Assert-AIChatPathWithinRoot -Path $Destination -Root $ProtectedRoot
    $parent = Split-Path -Parent $destinationPath
    [void](Assert-AIChatPrivateDirectoryTree -Path $parent -ProtectedRoot $ProtectedRoot)
    $existing = Get-Item -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        [void](Assert-AIChatPrivateFile -Path $destinationPath -ProtectedRoot $ProtectedRoot)
    }
    $temporary = "$destinationPath.tmp-$([Guid]::NewGuid().ToString('N'))"
    $replacementBackup = "$destinationPath.bak-$([Guid]::NewGuid().ToString('N'))"
    try {
        Copy-Item -LiteralPath $sourcePath -Destination $temporary
        if ((Get-AIChatHardLinkCount -Path $temporary) -ne 1) {
            throw "Private file copy temporary has a hardlink alias"
        }
        Set-AIChatCurrentSidOnlyAcl -Path $temporary
        if ($null -ne $existing) {
            [IO.File]::Replace($temporary, $destinationPath, $replacementBackup)
            if (Test-Path -LiteralPath $replacementBackup) {
                if ((Get-AIChatHardLinkCount -Path $replacementBackup) -ne 1) {
                    throw "Private file replacement backup has a hardlink alias"
                }
                Set-AIChatCurrentSidOnlyAcl -Path $replacementBackup
                Remove-Item -LiteralPath $replacementBackup -Force
            }
        } else {
            [IO.File]::Move($temporary, $destinationPath)
        }
        Set-AIChatCurrentSidOnlyAcl -Path $destinationPath
        [void](Assert-AIChatPrivateFile -Path $destinationPath -ProtectedRoot $ProtectedRoot)
    } finally {
        foreach ($residue in @($temporary, $replacementBackup)) {
            if (Test-Path -LiteralPath $residue) {
                $residueItem = Get-Item -LiteralPath $residue -Force
                if ($residueItem.PSIsContainer -or
                    ($residueItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                    (Get-AIChatHardLinkCount -Path $residue) -ne 1) {
                    throw "Unsafe private file copy residue requires manual inspection: $residue"
                }
                Set-AIChatCurrentSidOnlyAcl -Path $residue
                Remove-Item -LiteralPath $residue -Force
            }
        }
    }
}

function Get-AIChatDeploymentTargets {
    param([Parameter(Mandatory = $true)]$Paths)
    return [ordered]@{
        common = $Paths.CommonPath
        launcher = $Paths.LauncherPath
        settings = $Paths.SettingsPath
        mapping_state = $Paths.MappingStatePath
        active_release = $Paths.ActiveReleasePath
    }
}

function Restore-AIChatTaskSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)]$Paths
    )
    $mode = if ($Snapshot.PSObject.Properties["mode"]) {
        [string]$Snapshot.mode
    } else { "managed" }
    if ($mode -eq "untouched") { return }
    if ($mode -ne "managed") {
        throw "Scheduled Task rollback mode is invalid"
    }

    $current = Get-AIChatConnectorTask
    if ($null -ne $current) {
        Assert-AIChatTaskContract -Task $current -Paths $Paths
    }
    if ([bool]$Snapshot.existed) {
        if ([bool]$Snapshot.enabled) {
            throw "Rollback snapshot would restore an enabled connector task"
        }
        if (-not $Snapshot.PSObject.Properties["xml"] -or
            -not $Snapshot.PSObject.Properties["xml_sha256"] -or
            (Get-AIChatSha256Text -Value ([string]$Snapshot.xml)) -ne
                ([string]$Snapshot.xml_sha256).ToLowerInvariant()) {
            throw "Scheduled Task rollback snapshot hash is invalid"
        }
        if ($null -ne $current -and
            (Get-AIChatSha256Text -Value ([string]$current.Xml)) -eq
                ([string]$Snapshot.xml_sha256).ToLowerInvariant()) {
            return
        }
        $service = New-Object -ComObject "Schedule.Service"
        $service.Connect()
        try {
            $folder = $service.GetFolder("\AIChat")
        } catch {
            if (-not (Test-AIChatTaskSchedulerNotFoundException -Exception $_.Exception)) {
                throw
            }
            $folder = $service.GetFolder("\").CreateFolder("AIChat", $null)
        }
        [void]$folder.RegisterTask(
            "CodexConnector",
            [string]$Snapshot.xml,
            6,
            (Get-AIChatCurrentSid),
            $null,
            3,
            $null
        )
        $restored = Get-AIChatConnectorTask
        Assert-AIChatManagedTask -Task $restored
        Assert-AIChatTaskContract -Task $restored -Paths $Paths
    } elseif ($null -eq $current) {
        return
    } else {
        $service = New-Object -ComObject "Schedule.Service"
        $service.Connect()
        $folder = $service.GetFolder("\AIChat")
        $folder.DeleteTask("CodexConnector", 0)
    }
}

function Assert-AIChatTransactionManifest {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$BackupDirectory,
        [string[]]$AllowedStatuses = @("prepared", "applying", "applied", "committed", "rollback_incomplete"),
        [scriptblock]$DiagnosticCodeSink
    )
    if ($null -ne $DiagnosticCodeSink) {
        & $DiagnosticCodeSink "manifest_invalid"
    }
    $schemaVersion = if ($Manifest.PSObject.Properties["schema_version"]) {
        [int]$Manifest.schema_version
    } else { 0 }
    if ($schemaVersion -notin @(1, 2, 3, 4) -or
        -not $Manifest.PSObject.Properties["kind"] -or
        [string]$Manifest.kind -ne "aichat-windows-connector-transaction" -or
        -not $Manifest.PSObject.Properties["transaction_id"] -or
        [string]$Manifest.transaction_id -notmatch '^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$' -or
        -not $Manifest.PSObject.Properties["status"] -or
        $AllowedStatuses -notcontains [string]$Manifest.status) {
        throw "Windows connector transaction manifest schema is invalid"
    }
    $expectedBackupDirectory = Join-Path $Paths.BackupsDirectory ([string]$Manifest.transaction_id)
    if (-not ([IO.Path]::GetFullPath($BackupDirectory)).Equals(
        [IO.Path]::GetFullPath($expectedBackupDirectory),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Windows connector transaction backup directory is not fixed"
    }
    if ($null -ne $DiagnosticCodeSink) {
        & $DiagnosticCodeSink "file_snapshot_mismatch"
    }
    $targets = Get-AIChatDeploymentTargets -Paths $Paths
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($Manifest.files)) {
        $id = [string]$entry.id
        if (-not $targets.Contains($id) -or -not $seen.Add($id)) {
            throw "Windows connector transaction contains an invalid file target ID"
        }
        if ([bool]$entry.existed) {
            $backup = Join-Path $BackupDirectory "$id.bak"
            [void](Assert-AIChatPrivateFile -Path $backup -ProtectedRoot $Paths.ProtectedRoot)
            $hash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant()
            if (-not $entry.PSObject.Properties["sha256"] -or
                $hash -ne ([string]$entry.sha256).ToLowerInvariant()) {
                throw "Windows connector transaction backup hash is invalid"
            }
        }
    }
    $hasMappingState = $seen.Contains("mapping_state")
    $hasConnectorAcl = $null -ne $Manifest.PSObject.Properties["connector_data_acl"]
    $legacyV1 = $schemaVersion -eq 1 -and
        -not $hasMappingState -and -not $hasConnectorAcl -and
        $seen.Count -eq ($targets.Count - 1)
    # Two schema-v2 builds existed independently before integration. Accept
    # either historical shape fail-closed; current installs emit schema v4.
    $aclOnlyV2 = $schemaVersion -eq 2 -and
        -not $hasMappingState -and $hasConnectorAcl -and
        $seen.Count -eq ($targets.Count - 1)
    $mappingOnlyV2 = $schemaVersion -eq 2 -and
        $hasMappingState -and -not $hasConnectorAcl -and
        $seen.Count -eq $targets.Count
    $integratedV3 = $schemaVersion -eq 3 -and
        $hasMappingState -and $hasConnectorAcl -and
        $seen.Count -eq $targets.Count
    $integratedV4 = $schemaVersion -eq 4 -and
        $hasMappingState -and $hasConnectorAcl -and
        $seen.Count -eq $targets.Count
    if (-not $legacyV1 -and -not $aclOnlyV2 -and
        -not $mappingOnlyV2 -and -not $integratedV3 -and
        -not $integratedV4) {
        throw "Windows connector transaction does not cover every fixed file target"
    }
    if ($null -ne $DiagnosticCodeSink) {
        & $DiagnosticCodeSink "manifest_invalid"
    }
    if (-not $Manifest.PSObject.Properties["task"] -or
        -not $Manifest.PSObject.Properties["new_release_id"] -or
        [string]$Manifest.new_release_id -ne [string]$Manifest.transaction_id) {
        throw "Windows connector transaction task/release snapshot is invalid"
    }
    if ($hasConnectorAcl) {
        if ($null -ne $DiagnosticCodeSink) {
            & $DiagnosticCodeSink "acl_snapshot_mismatch"
        }
        Assert-AIChatConnectorDataAclSnapshot -Snapshot $Manifest.connector_data_acl
    }
    if ($null -ne $DiagnosticCodeSink) {
        & $DiagnosticCodeSink "task_snapshot_mismatch"
    }
    $taskMode = if ($Manifest.task.PSObject.Properties["mode"]) {
        [string]$Manifest.task.mode
    } else { "managed" }
    if ($taskMode -notin @("managed", "untouched") -or
        ($schemaVersion -eq 4 -and
            -not $Manifest.task.PSObject.Properties["mode"]) -or
        ($schemaVersion -lt 4 -and $taskMode -ne "managed")) {
        throw "Windows connector transaction task mode is invalid"
    }
    if ($taskMode -eq "untouched") {
        if ($schemaVersion -ne 4 -or
            @($Manifest.task.PSObject.Properties).Count -ne 1) {
            throw "Stage-only transaction must not contain a Scheduled Task snapshot"
        }
    } elseif (-not $Manifest.task.PSObject.Properties["existed"]) {
        throw "Windows connector transaction task snapshot is invalid"
    } elseif ([bool]$Manifest.task.existed) {
        if ([bool]$Manifest.task.enabled -or
            -not $Manifest.task.PSObject.Properties["xml"] -or
            -not $Manifest.task.PSObject.Properties["xml_sha256"] -or
            (Get-AIChatSha256Text -Value ([string]$Manifest.task.xml)) -ne
                ([string]$Manifest.task.xml_sha256).ToLowerInvariant()) {
            throw "Windows connector transaction task snapshot is invalid"
        }
    }
}

function Invoke-AIChatManifestRollback {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$BackupDirectory,
        [switch]$RestoreConnectorDataAcl
    )
    Assert-AIChatTransactionManifest `
        -Manifest $Manifest `
        -Paths $Paths `
        -BackupDirectory $BackupDirectory

    $taskMode = if ($Manifest.task.PSObject.Properties["mode"]) {
        [string]$Manifest.task.mode
    } else { "managed" }
    if ($taskMode -eq "managed") {
        $currentTask = Get-AIChatConnectorTask
        if ($null -ne $currentTask) {
            Assert-AIChatTaskContract -Task $currentTask -Paths $Paths
        }
    }
    $targets = Get-AIChatDeploymentTargets -Paths $Paths
    $entries = @($Manifest.files)
    $manifestHasMappingState = @(
        $entries | Where-Object { [string]$_.id -eq "mapping_state" }
    ).Count -eq 1
    [array]::Reverse($entries)
    foreach ($entry in $entries) {
        $target = [string]$targets[[string]$entry.id]
        if ([bool]$entry.existed) {
            Copy-AIChatPrivateFileAtomic `
                -Source (Join-Path $BackupDirectory "$([string]$entry.id).bak") `
                -Destination $target `
                -ProtectedRoot $Paths.ProtectedRoot
        } elseif (Test-Path -LiteralPath $target) {
            [void](Assert-AIChatPrivateFile -Path $target -ProtectedRoot $Paths.ProtectedRoot)
            Remove-Item -LiteralPath $target -Force
        }
    }
    if (-not $manifestHasMappingState -and
        (Test-Path -LiteralPath $Paths.MappingStatePath)) {
        [void](Assert-AIChatPrivateFile `
            -Path $Paths.MappingStatePath `
            -ProtectedRoot $Paths.ProtectedRoot)
        Remove-Item -LiteralPath $Paths.MappingStatePath -Force
    }

    $release = Join-Path $Paths.ReleasesDirectory ([string]$Manifest.new_release_id)
    if (Test-Path -LiteralPath $release) {
        [void](Assert-AIChatPrivateDirectoryTree `
            -Path $release `
            -ProtectedRoot $Paths.ProtectedRoot)
        $failedRoot = Initialize-AIChatPrivateDirectory `
            -Path (Join-Path $Paths.StateRoot "failed") `
            -ProtectedRoot $Paths.ProtectedRoot
        $failed = Join-Path $failedRoot ([string]$Manifest.new_release_id)
        if (Test-Path -LiteralPath $failed) {
            throw "Rollback failed-release destination already exists"
        }
        Move-Item -LiteralPath $release -Destination $failed
    }
    Restore-AIChatTaskSnapshot -Snapshot $Manifest.task -Paths $Paths
    if ($RestoreConnectorDataAcl -and
        $Manifest.PSObject.Properties["connector_data_acl"]) {
        Restore-AIChatConnectorDataAclSnapshot `
            -Snapshot $Manifest.connector_data_acl `
            -Path $Paths.ConnectorDataRoot
    }
}

function Assert-AIChatManifestRollbackNonAclComplete {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$BackupDirectory,
        [scriptblock]$TaskProvider,
        [scriptblock]$DiagnosticCodeSink
    )

    Assert-AIChatTransactionManifest `
        -Manifest $Manifest `
        -Paths $Paths `
        -BackupDirectory $BackupDirectory `
        -AllowedStatuses @("rollback_incomplete") `
        -DiagnosticCodeSink $DiagnosticCodeSink
    if ($null -ne $DiagnosticCodeSink) {
        & $DiagnosticCodeSink "manifest_invalid"
    }
    $schemaVersion = [int]$Manifest.schema_version
    $taskMode = if ($Manifest.task.PSObject.Properties["mode"]) {
        [string]$Manifest.task.mode
    } else { "managed" }
    $managedV3 = $schemaVersion -eq 3 -and $taskMode -eq "managed"
    $untouchedV4 = $schemaVersion -eq 4 -and $taskMode -eq "untouched"
    if (-not $managedV3 -and -not $untouchedV4) {
        throw "Automatic rollback finalization requires schema-v3 managed or schema-v4 untouched task state"
    }

    if ($null -ne $DiagnosticCodeSink) {
        & $DiagnosticCodeSink "file_snapshot_mismatch"
    }
    $targets = Get-AIChatDeploymentTargets -Paths $Paths
    foreach ($entry in @($Manifest.files)) {
        $target = [string]$targets[[string]$entry.id]
        if ([bool]$entry.existed) {
            [void](Assert-AIChatPrivateFile `
                -Path $target `
                -ProtectedRoot $Paths.ProtectedRoot)
            $currentHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($currentHash -ne ([string]$entry.sha256).ToLowerInvariant()) {
                throw "Rollback target content does not match its protected prior-state backup"
            }
        } elseif (Test-Path -LiteralPath $target) {
            throw "Rollback target exists although it was absent from the prior state"
        }
    }

    # A schema-v4 stage-only journal is an explicit no-task contract. Do not
    # invoke even an injected provider: production callers would otherwise
    # open Task Scheduler while merely verifying or finalizing this journal.
    if ($managedV3) {
        if ($null -ne $DiagnosticCodeSink) {
            & $DiagnosticCodeSink "task_snapshot_mismatch"
        }
        [void](Assert-AIChatTaskSnapshotForMutation `
            -Snapshot $Manifest.task `
            -Paths $Paths `
            -TaskProvider $TaskProvider)
    }

    if ($null -ne $DiagnosticCodeSink) {
        & $DiagnosticCodeSink "release_layout_mismatch"
    }
    $liveRelease = Join-Path $Paths.ReleasesDirectory ([string]$Manifest.new_release_id)
    if (Test-Path -LiteralPath $liveRelease) {
        throw "Failed transaction release is still present in the live releases directory"
    }
    $staging = Join-Path $Paths.StagingDirectory ([string]$Manifest.transaction_id)
    if (Test-Path -LiteralPath $staging) {
        throw "Failed transaction staging directory still exists"
    }
    $failedRelease = Join-Path `
        (Join-Path $Paths.StateRoot "failed") `
        ([string]$Manifest.new_release_id)
    if (Test-Path -LiteralPath $failedRelease) {
        [void](Get-AIChatTreeHash `
            -Root $failedRelease `
            -RequireCurrentSidOnlyAcl)
    }

    return [pscustomobject][ordered]@{
        transaction_id = [string]$Manifest.transaction_id
        schema_version = $schemaVersion
        file_targets_exact = $true
        task_mode = $taskMode
        task_snapshot_exact = $managedV3
        task_untouched = $untouchedV4
        task_scheduler_accessed = $managedV3
        live_release_absent = $true
        staging_absent = $true
        failed_release_preserved = Test-Path -LiteralPath $failedRelease -PathType Container
    }
}

function Assert-AIChatManifestRollbackComplete {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$BackupDirectory,
        [scriptblock]$TaskProvider,
        [scriptblock]$ConnectorDataAclSnapshotProvider,
        [scriptblock]$DiagnosticCodeSink
    )

    $nonAcl = Assert-AIChatManifestRollbackNonAclComplete `
        -Manifest $Manifest `
        -Paths $Paths `
        -BackupDirectory $BackupDirectory `
        -TaskProvider $TaskProvider `
        -DiagnosticCodeSink $DiagnosticCodeSink
    if ($null -ne $DiagnosticCodeSink) {
        & $DiagnosticCodeSink "acl_snapshot_mismatch"
    }
    $currentAclSnapshot = if ($null -eq $ConnectorDataAclSnapshotProvider) {
        Get-AIChatConnectorDataAclSnapshot -Path $Paths.ConnectorDataRoot
    } else {
        & $ConnectorDataAclSnapshotProvider
    }
    Assert-AIChatConnectorDataAclMatchesSnapshot `
        -Expected $Manifest.connector_data_acl `
        -Actual $currentAclSnapshot

    return [pscustomobject][ordered]@{
        transaction_id = [string]$nonAcl.transaction_id
        schema_version = [int]$nonAcl.schema_version
        file_targets_exact = [bool]$nonAcl.file_targets_exact
        task_mode = [string]$nonAcl.task_mode
        task_snapshot_exact = [bool]$nonAcl.task_snapshot_exact
        task_untouched = [bool]$nonAcl.task_untouched
        task_scheduler_accessed = [bool]$nonAcl.task_scheduler_accessed
        connector_data_acl_exact = $true
        live_release_absent = [bool]$nonAcl.live_release_absent
        staging_absent = [bool]$nonAcl.staging_absent
        failed_release_preserved = [bool]$nonAcl.failed_release_preserved
    }
}
