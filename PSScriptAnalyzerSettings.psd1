@{
    # PSScriptAnalyzer configuration for the DRaaC repo.
    #
    # Two rules are excluded project-wide because they conflict with explicit
    # rules in IMPLEMENTATION-BRIEF.md:
    #
    #   PSAvoidUsingWriteHost
    #     The brief's "Working conventions" mandate Write-Host for pipeline
    #     progress: "Write-Host for progress (visible in CI logs)". CI consumers
    #     read these lines, so swapping to Write-Information would silently break
    #     log capture.
    #
    #   PSUseBOMForUnicodeEncodedFile
    #     The brief mandates `Set-Content -Encoding UTF8` (UTF-8 without BOM)
    #     as the universal output encoding. The same encoding is used for the
    #     PowerShell source files themselves; suppressing this rule keeps the
    #     non-ASCII section separators we use in script headers without
    #     polluting every file with a BOM.
    #
    # Everything else (including PSReviewUnusedParameter, PSUseSingularNouns,
    # PSUseShouldProcessForStateChangingFunctions) is enforced per-file via
    # targeted SuppressMessageAttribute when the brief's API contract or
    # closure semantics force a deviation. New code without a justified
    # suppression must be warning-free.
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseBOMForUnicodeEncodedFile'
    )
}
