#!/usr/bin/env python3
"""
Claude Code PreToolUse Hook: Block Sensitive File Access
Place at: ~/.claude/hooks/block-sensitive-files.py

This hook intercepts Read/Edit/Write tool calls and blocks
access to sensitive files. More reliable than deny rules
which have known enforcement bugs.
"""

import json
import sys
import os
from pathlib import Path

# Sensitive file patterns
BLOCKED_NAMES = {
    ".env", ".env.local", ".env.production", ".env.staging",
    ".env.development", ".env.test",
    "credentials", "credentials.json",
    "secrets.json", "secrets.yaml", "secrets.yml",
    "id_rsa", "id_ed25519", "id_ecdsa",
    "known_hosts",
    ".npmrc",  # may contain auth tokens
    ".netrc",
    ".pgpass",
}

BLOCKED_EXTENSIONS = {
    ".pem", ".key", ".p12", ".pfx", ".jks",
}

BLOCKED_DIRS = {
    ".aws", ".ssh", ".gnupg", ".config/gcloud",
}

def is_blocked(file_path_str: str) -> tuple[bool, str]:
    if not file_path_str:
        return False, ""
    
    p = Path(file_path_str)
    
    # Check filename
    if p.name in BLOCKED_NAMES:
        return True, f"Blocked file name: {p.name}"
    
    # Check .env.* pattern
    if p.name.startswith(".env"):
        return True, f"Blocked .env variant: {p.name}"
    
    # Check extension
    if p.suffix.lower() in BLOCKED_EXTENSIONS:
        return True, f"Blocked extension: {p.suffix}"
    
    # Check if inside blocked directory
    parts = p.parts
    for d in BLOCKED_DIRS:
        for part in d.split("/"):
            if part in parts:
                return True, f"Blocked directory: {d}"
    
    return False, ""

def main():
    try:
        data = json.load(sys.stdin)
        tool_input = data.get("tool_input", {})
        
        # Read/Edit/Write tools use file_path
        file_path = tool_input.get("file_path", "")
        
        blocked, reason = is_blocked(file_path)
        if blocked:
            print(json.dumps({
                "decision": "block",
                "reason": f"SECURITY_POLICY: {reason}. Use environment variables or a secrets manager instead."
            }))
            sys.exit(2)
        
        # Allow
        sys.exit(0)
    except Exception as e:
        # On error, block (fail-close for security)
        print(json.dumps({
            "decision": "block",
            "reason": f"SECURITY_POLICY: Hook error — blocking as a safety precaution: {e}"
        }))
        sys.exit(2)

if __name__ == "__main__":
    main()
