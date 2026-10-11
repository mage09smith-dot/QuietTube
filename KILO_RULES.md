# KILO RULES - QuietTube 21.38.2 - ULTRA LOW TOKEN
RULE 1: NEVER read whole repo. Use grep + read_file limit 50.
RULE 2: Fix 1 check.sh failure per loop. After edit run: python scripts/verify_release.py
RULE 3: After editing Sources/*, update release-manifest.json sha256 ONLY for that file. Don't regenerate all.
RULE 4: Use local capture: IMP orig = global; block captures local orig copy.
RULE 5: youtubei filter = @"youtubei" not @"youtubei.googleapis.com"
RULE 6: Use diffEdits:true, maxContextTokens:40000
RULE 7: Planner = ollama/qwen2.5-coder:32b (FREE), Coder = claude-4.5-sonnet
