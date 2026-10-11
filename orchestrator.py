import subprocess, requests, json, time, re, hashlib
from pathlib import Path

# ---------------- CONFIG ----------------
REPO_PATH = r"C:\Users\volt\Documents\QuiteTube\QuietTube"
OLLAMA_URL = "http://localhost:11434/api/chat"
MODEL_NAME = "qwen2.5-coder:32b"
GITHUB_REPO = "mage09smith-dot/QuietTube"
BASE_IPA_URL = "https://www.dropbox.com/scl/fi/1j3g4asvdit41uix17q2e/com.google.ios.youtube-21.38.2-Decrypted.ipa?rlkey=78sw9yuzqf1wbcyeej94qhjmz&st=hf349p27&dl=1"  # upload decrypted base once, reuse forever
BRANCH = "main"
MAX_ITERATIONS = 5

# Files the AI must NEVER touch (full-file hash pinned in tests/fixtures/preservation.json)
FROZEN_FILES = {
    "Sources/QTFeatures.m", "Sources/QTLogo.m", "Sources/QTAdProfile.m",
    "Sources/QTFeedInsertion.m", "Sources/QTMutationTrace.m",
    "Sources/QTInsertionPolicy.h", "Sources/QTFeedRules.h",
    "Sources/QTTemplateScan.h", "Sources/QTCore.m", "Sources/QTSettingsModel.m",
}
# Partially frozen: (file, marker_line) -> everything from marker_line to EOF must not change
PARTIAL_FROZEN = {
    "Sources/QTSettings.m": "static const void *QTRowMarker",
}

# ---------------- STEP 0: Local pre-flight (optional but recommended) ----------------
def run_preflight():
    print("Running scripts/iterate.sh as a local sanity check...")
    result = subprocess.run(["bash", "scripts/iterate.sh"], cwd=REPO_PATH,
                             capture_output=True, text=True)
    print(result.stdout[-2000:])
    if result.returncode != 0:
        print("⚠️ iterate.sh reported issues — review before pushing.")
    return result.stdout

# ---------------- STEP 1: Context ----------------
def gather_context(task_description, relevant_modules):
    context = f"=== TASK ===\n{task_description}\n\n"

    pres_path = Path(REPO_PATH) / "tests/fixtures/preservation.json"
    if pres_path.exists():
        context += "=== PRESERVATION CONSTRAINTS (tests/fixtures/preservation.json) ===\n"
        context += pres_path.read_text() + "\n\n"

    abi_path = Path(REPO_PATH) / "tests/fixtures/native-abi.json"
    if abi_path.exists():
        context += "=== NATIVE ABI — PROTECTED SELECTORS ===\n"
        context += abi_path.read_text() + "\n\n"

    fix_notes = Path(REPO_PATH) / "FIX_NOTES.md"
    if fix_notes.exists():
        context += "=== EXAMPLE OF EXPECTED FIX STYLE/DEPTH (FIX_NOTES.md) ===\n"
        context += fix_notes.read_text()[:3000] + "\n\n"

    context += "=== SOURCE FILES ===\n"
    for module in relevant_modules:
        for ext in [".h", ".m"]:
            f = Path(REPO_PATH) / "Sources" / f"{module}{ext}"
            if f.exists():
                context += f"\n--- FILE: Sources/{module}{ext} ---\n{f.read_text()}\n"
    return context

# ---------------- STEP 2: Ask the model ----------------
def ask_model_for_fix(context, task_description):
    frozen_list = "\n".join(f"- {f}" for f in FROZEN_FILES)
    partial_list = "\n".join(f"- {f} (only code BEFORE the line: {m})"
                              for f, m in PARTIAL_FROZEN.items())

    system_prompt = (
        "You are an expert Objective-C / Mach-O runtime hooking engineer working on QuietTube, "
        "an iOS dylib that hooks private YouTube methods by exact selector name and @encode type "
        "signature via a QTHook() primitive.\n\n"
        "ABSOLUTE RULES:\n"
        f"1. NEVER modify these files at all, under any circumstance:\n{frozen_list}\n"
        f"2. In these files, only edit code ABOVE the stated marker line — leave everything from "
        f"that marker to end-of-file byte-identical:\n{partial_list}\n"
        "3. NEVER remove or rename a selector listed in the native-abi.json protected selectors.\n"
        "4. Preserve all existing QTDEvent()/QTCount() diagnostic calls — do not remove them.\n"
        "5. Preserve NSUserDefaults key names exactly (QuietTube.v1.* prefix).\n"
        "6. Use the hook-safety pattern: capture IMP into a local variable before the block, so the "
        "block closes over a local copy, not a mutable global (prevents recursion/chain bugs).\n"
        "7. Match the existing string-matching convention already used in the file you're editing "
        "(e.g. full host string vs short substring) — don't impose a different convention.\n"
        "8. Output COMPLETE file contents for every file touched, in this exact format:\n\n"
        "### FILE: Sources/QTExample.m\n```objc\n<complete file>\n```\n\n"
        "Do not use diffs or partial snippets. Do not stop until the full task is addressed."
    )

    payload = {
    "model": MODEL_NAME,
    "messages": [...],
    "stream": False,
    "keep_alive": "30m",   # ADD THIS — keeps model loaded between iterations
    "options": {"temperature": 0.3, "num_predict": 6144, "num_ctx": 8192}
    }
    resp = requests.post(OLLAMA_URL, json=payload, timeout=900)
    resp.raise_for_status()
    return resp.json()["message"]["content"]

# ---------------- STEP 3: Parse + Guardrail Check ----------------
def apply_fix(model_output):
    pattern = r"### FILE: (.+?)\n```(?:\w+)?\n(.*?)```"
    matches = re.findall(pattern, model_output, re.DOTALL)
    changed_files = []

    for filepath, content in matches:
        filepath = filepath.strip()
        normalized = filepath.replace("\\", "/")

        if normalized in FROZEN_FILES:
            print(f"🛑 BLOCKED: AI tried to edit frozen file {filepath}. Skipping this file.")
            continue

        if normalized in PARTIAL_FROZEN:
            marker = PARTIAL_FROZEN[normalized]
            old_path = Path(REPO_PATH) / filepath
            if old_path.exists():
                old_text = old_path.read_text()
                if marker in old_text:
                    old_tail = old_text[old_text.index(marker):]
                    if marker in content:
                        new_tail = content[content.index(marker):]
                        if new_tail.strip() != old_tail.strip():
                            print(f"🛑 BLOCKED: {filepath} changed protected tail after '{marker}'. Skipping.")
                            continue
                    else:
                        print(f"🛑 BLOCKED: {filepath} is missing the protected marker '{marker}'. Skipping.")
                        continue

        full_path = Path(REPO_PATH) / filepath
        full_path.parent.mkdir(parents=True, exist_ok=True)
        full_path.write_text(content.strip() + "\n")
        changed_files.append(filepath)
        print(f"✅ Wrote: {filepath}")

    return changed_files

# ---------------- STEP 4: Update release-manifest.json for edited Sources/* ----------------
def update_manifest_hashes(changed_files):
    manifest_path = Path(REPO_PATH) / "release-manifest.json"
    if not manifest_path.exists():
        return
    manifest = json.loads(manifest_path.read_text())
    sha_dict = manifest.setdefault("sha256", {})
    updated = False

    for filepath in changed_files:
        normalized = filepath.replace("\\", "/")
        full_path = Path(REPO_PATH) / normalized
        if not full_path.exists():
            continue
        new_hash = hashlib.sha256(full_path.read_bytes()).hexdigest()
        if sha_dict.get(normalized) != new_hash:
            sha_dict[normalized] = new_hash
            updated = True
            print(f"📝 Updated manifest hash: {normalized}")

    if updated:
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

# ---------------- STEP 5: Git ----------------
def git_commit_and_push(changed_files, message):
    subprocess.run(["git", "add"] + changed_files + ["release-manifest.json"],
                    cwd=REPO_PATH, check=True)
    subprocess.run(["git", "commit", "-m", message], cwd=REPO_PATH, check=True)
    subprocess.run(["git", "push", "origin", BRANCH], cwd=REPO_PATH, check=True)
    print("✅ Pushed to GitHub")

# ---------------- STEP 6: Trigger workflow ----------------
def trigger_build():
    subprocess.run([
        "gh", "workflow", "run", "build.yml",
        "--repo", GITHUB_REPO,
        "-f", f"base_ipa_url={BASE_IPA_URL}",
        "-f", "acknowledge_rights=true"
    ], check=True)
    print("🚀 Build triggered")

def get_latest_run_id():
    time.sleep(10)
    result = subprocess.run(
        ["gh", "run", "list", "--repo", GITHUB_REPO, "--workflow=build.yml",
         "--limit", "1", "--json", "databaseId,status,conclusion"],
        capture_output=True, text=True, check=True
    )
    return json.loads(result.stdout)[0]

def wait_for_run(timeout_sec=1500):
    start = time.time()
    while time.time() - start < timeout_sec:
        run = get_latest_run_id()
        if run["status"] == "completed":
            return run
        time.sleep(20)
    raise TimeoutError("Build did not finish in time")

def get_run_log(run_id):
    result = subprocess.run(
        ["gh", "run", "view", str(run_id), "--repo", GITHUB_REPO, "--log"],
        capture_output=True, text=True, check=True
    )
    return result.stdout

# ---------------- STEP 7: Download from RELEASE (not artifact!) ----------------
def get_latest_release_tag():
    result = subprocess.run(
        ["gh", "release", "list", "--repo", GITHUB_REPO, "--limit", "1", "--json", "tagName"],
        capture_output=True, text=True, check=True
    )
    releases = json.loads(result.stdout)
    return releases[0]["tagName"] if releases else None

def download_release(tag, dest="downloaded_ipa"):
    subprocess.run(
        ["gh", "release", "download", tag, "--repo", GITHUB_REPO, "--dir", dest, "--clobber"],
        check=True
    )
    print(f"📦 Release assets downloaded to {dest}")

# ---------------- MAIN LOOP ----------------
def main():
    task = input("Describe the bug/feature to fix: ")
    modules = input("Which modules (comma-separated, e.g. QTStreamFallback,QTPlaybackFix): ").split(",")
    modules = [m.strip() for m in modules]

    feedback = ""
    for i in range(MAX_ITERATIONS):
        print(f"\n===== ITERATION {i+1} =====")
        context = gather_context(task + "\n" + feedback, modules)
        output = ask_model_for_fix(context, task)
        changed = apply_fix(output)

        if not changed:
            print("⚠️ No valid file changes produced. Raw output:\n", output[:1500])
            break

        update_manifest_hashes(changed)
        run_preflight()
        git_commit_and_push(changed, f"AI iteration {i+1}: {task}")
        trigger_build()

        run = wait_for_run()
        if run["conclusion"] == "success":
            tag = get_latest_release_tag()
            download_release(tag)
            print(f"🎉 SUCCESS — release {tag} downloaded to ./downloaded_ipa")
            break
        else:
            print("❌ Build failed — pulling logs for next iteration")
            log = get_run_log(run["databaseId"])
            feedback = "=== PREVIOUS BUILD FAILURE LOG ===\n" + log[-6000:]

if __name__ == "__main__":
    main()