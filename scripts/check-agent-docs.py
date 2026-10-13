#!/usr/bin/env python3
"""Check active AI navigation and skill metadata without building the app."""

import argparse
import re
from pathlib import Path
from urllib.parse import unquote, urlsplit


SKILLS = ("piclight-development", "piclight-verification", "piclight-review")
REQUIRED = (
    "AGENTS.md", "README.md", ".agents/README.md", ".agents/notes/README.md",
    "docs/development.md", "docs/testing.md",
) + tuple(f".agents/skills/{name}/SKILL.md" for name in SKILLS)


def prose_only(text):
    """Exclude fenced and inline examples from navigation checks."""
    lines = []
    fence = None
    for line in text.splitlines():
        marker = re.match(r"^\s*(`{3,}|~{3,})(.*)$", line)
        if marker:
            chars, rest = marker.groups()
            if fence is None:
                fence = chars
            elif chars[0] == fence[0] and len(chars) >= len(fence) and not rest.strip():
                fence = None
            continue
        if fence is None:
            lines.append(re.sub(r"(`+).*?\1", "", line))
    return "\n".join(lines)


def check(root):
    errors = []
    for relative in REQUIRED:
        if not (root / relative).is_file():
            errors.append(f"{relative}: required file missing")
    paths = {root / name for name in REQUIRED if (root / name).is_file()}
    if (root / ".agents").is_dir():
        paths.update(path for path in (root / ".agents").rglob("*.md")
                     if not path.is_relative_to(root / ".agents/notes/archived"))
    for path in sorted(paths):
        relative = path.relative_to(root).as_posix()
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            errors.append(f"{relative}: cannot read UTF-8 text: {error}")
            continue
        if not text.endswith("\n") or text.endswith("\n\n"):
            errors.append(f"{relative}: end with exactly one newline")
        if path.name == "SKILL.md":
            front = re.match(r"\A---\n(.*?)\n---\n", text, re.S)
            if not front:
                errors.append(f"{relative}: YAML frontmatter missing")
            else:
                fields = dict(re.findall(r"^(name|description):[ \t]*(.*)$", front[1], re.M))
                name = fields.get("name", "").strip().strip("\"'")
                description = fields.get("description", "").strip().strip("\"'")
                if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name) or len(name) > 64:
                    errors.append(f"{relative}: invalid skill name {name!r}")
                elif name != path.parent.name:
                    errors.append(f"{relative}: name {name!r} must match directory")
                if not description or description in ("|", ">") or len(description) > 1024:
                    errors.append(f"{relative}: description requires a non-empty single-line value")
        if relative.startswith(".agents/notes/") and path.name != "README.md":
            lifecycle = path.relative_to(root / ".agents/notes").parts[0]
            if lifecycle in ("proposed", "implemented", "rejected"):
                status = re.search(r"^Status: (proposed|implemented|rejected)(?:\s|$)", text, re.M)
                if not status or status[1] != lifecycle:
                    errors.append(f"{relative}: Status must match {lifecycle} directory")
        prose = prose_only(text)
        targets = [angle or plain for angle, plain in re.findall(
            r"!?\[[^\]\n]+\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+\"[^\"]*\")?\s*\)", prose)]
        targets += [angle or plain for angle, plain in re.findall(
            r"^\[[^\]\n]+\]:\s*(?:<([^>]+)>|([^\s]+))", prose, re.M)]
        for target in targets:
            parsed = urlsplit(target)
            if parsed.scheme or parsed.netloc or not parsed.path:
                continue
            file_part = unquote(parsed.path)
            if file_part.startswith("/"):
                errors.append(f"{relative}: non-portable absolute link {target}")
                continue
            destination = (path.parent / file_part).resolve()
            if not destination.is_relative_to(root) or not destination.exists():
                errors.append(f"{relative}: local link missing or outside repository: {target}")
    return len(paths), errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1],
                        help="repository root (also supports isolated validation fixtures)")
    root = parser.parse_args().root.resolve()
    count, errors = check(root)
    for error in errors:
        print(f"FAIL {error}")
    print(f"agent docs: {count} Markdown files checked, {len(errors)} failures")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
