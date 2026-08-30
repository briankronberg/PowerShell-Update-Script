function Remove-JsonComment {
    # Windows Terminal's settings.json is JSONC. Windows PowerShell 5.1's parser
    # rejects comments outright, so strip them before parsing. The alternation
    # matches whole string literals first, so a "//" inside a path or URL value is
    # preserved rather than being mistaken for a comment.
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        if ($m.Groups[1].Success) { $m.Groups[1].Value } else { '' }
    }
    [regex]::Replace($Text, '("(?:\\.|[^"\\])*")|/\*[\s\S]*?\*/|//[^\r\n]*', $evaluator)
}
