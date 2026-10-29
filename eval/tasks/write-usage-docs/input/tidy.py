#!/usr/bin/env python3
"""A simple Markdown formatter and linter."""

import argparse
import difflib
import fnmatch
import glob
import json
import os
import re
import sys
import textwrap
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Union

try:
    import tomllib
except ImportError:
    import tomli as tomllib  # type: ignore

__version__ = "0.1.0"

DEFAULT_CONFIG_PATHS = [
    Path.home() / ".config" / "tidy" / "config.toml",
    Path.cwd() / ".tidy.toml",
]

class Config:
    """Configuration for tidy."""

    def __init__(self, data: Optional[Dict] = None):
        self.data = data or {}
        self.line_width = self.data.get("line_width", 80)
        self.bullet = self.data.get("bullet", "-")
        self.no_final_newline = self.data.get("no_final_newline", False)
        self.max_heading_level = self.data.get("max_heading_level", 4)
        self.allow_html = self.data.get("allow_html", False)

    @classmethod
    def from_file(cls, path: Optional[Path] = None) -> "Config":
        """Load config from a file."""
        if path is None:
            for p in DEFAULT_CONFIG_PATHS:
                if p.exists():
                    path = p
                    break
            else:
                return cls()

        try:
            with open(path, "rb") as f:
                data = tomllib.load(f)
        except (FileNotFoundError, tomllib.TOMLDecodeError):
            return cls()

        return cls(data)

    def __repr__(self) -> str:
        return f"Config({self.data})"

def load_config(args: argparse.Namespace) -> Config:
    """Load the configuration."""
    if args.config:
        return Config.from_file(Path(args.config))
    return Config.from_file()

def wrap_text(text: str, width: int) -> str:
    """Wrap text to the given width."""
    return "\n".join(textwrap.wrap(text, width=width))

def normalize_bullets(text: str, bullet: str) -> str:
    """Normalize bullet points to the given style."""
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if line.strip().startswith(("- ", "* ", "+ ")):
            lines[i] = f"{bullet} {line.lstrip('-+* ')}"
    return "\n".join(lines)

def ensure_final_newline(text: str, no_final_newline: bool) -> str:
    """Ensure the text has or doesn't have a final newline."""
    if no_final_newline:
        return text.rstrip("\n")
    return text if text.endswith("\n") else text + "\n"

def format_markdown(
    content: str,
    line_width: int,
    bullet: str,
    no_final_newline: bool,
) -> str:
    """Format the given Markdown content."""
    # Wrap paragraphs
    paragraphs = re.split(r"\n{2,}", content)
    wrapped = []
    for para in paragraphs:
        if para.strip().startswith(("#", "- ", "* ", "+ ", "1. ")):
            wrapped.append(para)
        else:
            wrapped.append(wrap_text(para, line_width))

    formatted = "\n\n".join(wrapped)

    # Normalize bullets
    formatted = normalize_bullets(formatted, bullet)

    # Handle final newline
    formatted = ensure_final_newline(formatted, no_final_newline)

    return formatted

def check_heading_levels(content: str, max_level: int) -> List[str]:
    """Check for headings that exceed the maximum level."""
    errors = []
    for i, line in enumerate(content.split("\n")):
        if line.startswith("#"):
            level = len(line.split()[0])
            if level > max_level:
                errors.append(f"Line {i+1}: Heading level {level} exceeds max {max_level}")
    return errors

def check_raw_html(content: str, allow_html: bool) -> List[str]:
    """Check for raw HTML."""
    if allow_html:
        return []
    errors = []
    for i, line in enumerate(content.split("\n")):
        if re.search(r"<[a-zA-Z]", line):
            errors.append(f"Line {i+1}: Raw HTML detected")
    return errors

def lint_markdown(
    content: str,
    max_heading_level: int,
    allow_html: bool,
) -> List[str]:
    """Lint the given Markdown content."""
    errors = []
    errors.extend(check_heading_levels(content, max_heading_level))
    errors.extend(check_raw_html(content, allow_html))
    return errors

def process_files(
    paths: List[str],
    exclude: List[str],
    func: callable,
    **kwargs,
) -> Tuple[int, List[str]]:
    """Process files with the given function."""
    exit_code = 0
    messages = []

    for path in paths:
        for file in glob.glob(path, recursive=True):
            if any(fnmatch.fnmatch(file, pattern) for pattern in exclude):
                continue

            try:
                with open(file, "r") as f:
                    content = f.read()
            except (IOError, UnicodeDecodeError) as e:
                messages.append(f"Error reading {file}: {e}")
                exit_code = 2
                continue

            result = func(content, **kwargs)

            if isinstance(result, str):
                if result != content:
                    messages.append(f"Would change: {file}")
                    exit_code = 1
            elif isinstance(result, list):
                if result:
                    messages.append(f"Lint errors in {file}:")
                    messages.extend(result)
                    exit_code = 1

    return exit_code, messages

def format_command(args: argparse.Namespace) -> int:
    """Format Markdown files."""
    config = load_config(args)
    line_width = int(os.getenv("TIDY_LINE_WIDTH", args.line_width or config.line_width))
    bullet = args.bullet or config.bullet
    no_final_newline = args.no_final_newline or config.no_final_newline

    def format_func(content: str) -> str:
        return format_markdown(
            content,
            line_width=line_width,
            bullet=bullet,
            no_final_newline=no_final_newline,
        )

    exit_code, messages = process_files(
        args.path,
        args.exclude,
        format_func,
        line_width=line_width,
        bullet=bullet,
        no_final_newline=no_final_newline,
    )

    if args.check and exit_code == 0:
        print("No files would be changed.")
        return 0

    if args.diff and exit_code == 1:
        for path in args.path:
            for file in glob.glob(path, recursive=True):
                if any(fnmatch.fnmatch(file, pattern) for pattern in args.exclude):
                    continue

                try:
                    with open(file, "r") as f:
                        original = f.read()
                except (IOError, UnicodeDecodeError):
                    continue

                formatted = format_func(original)
                if formatted != original:
                    diff = difflib.unified_diff(
                        original.splitlines(keepends=True),
                        formatted.splitlines(keepends=True),
                        fromfile=f"a/{file}",
                        tofile=f"b/{file}",
                    )
                    print("".join(diff), end="")

    if messages and not args.quiet:
        print("\n".join(messages))

    return exit_code

def lint_command(args: argparse.Namespace) -> int:
    """Lint Markdown files."""
    config = load_config(args)
    max_heading_level = args.max_heading_level or config.max_heading_level
    allow_html = args.allow_html or config.allow_html

    def lint_func(content: str) -> List[str]:
        return lint_markdown(
            content,
            max_heading_level=max_heading_level,
            allow_html=allow_html,
        )

    exit_code, messages = process_files(
        args.path,
        args.exclude,
        lint_func,
        max_heading_level=max_heading_level,
        allow_html=allow_html,
    )

    if messages and not args.quiet:
        if args.format == "json":
            print(json.dumps({"errors": messages}, indent=2))
        else:
            print("\n".join(messages))

    return exit_code

def config_command(args: argparse.Namespace) -> int:
    """Show or locate the configuration."""
    config = load_config(args)

    if args.show:
        print(config)
    elif args.path:
        if args.config:
            print(args.config)
        else:
            for p in DEFAULT_CONFIG_PATHS:
                if p.exists():
                    print(p)
                    break
            else:
                print("No config file found.")
    else:
        print("Use --show or --path.")

    return 0

def main() -> int:
    """Main entry point."""
    parser = argparse.ArgumentParser(description="A simple Markdown formatter and linter.")
    parser.add_argument("--config", help="Path to the config file.")
    parser.add_argument("--quiet", action="store_true", help="Suppress output.")
    parser.add_argument("--verbose", action="store_true", help="Enable verbose output.")
    parser.add_argument("--version", action="store_true", help="Show version and exit.")

    subparsers = parser.add_subparsers(dest="command", required=True)

    # Format command
    format_parser = subparsers.add_parser("format", help="Format Markdown files.")
    format_parser.add_argument("path", nargs="+", help="Files or glob patterns to format.")
    format_parser.add_argument("--line-width", type=int, help="Maximum line width.")
    format_parser.add_argument("--bullet", choices=["-", "*", "+"], help="Bullet style.")
    format_parser.add_argument("--no-final-newline", action="store_true", help="Don't add final newline.")
    format_parser.add_argument("--check", action="store_true", help="Check if files would change.")
    format_parser.add_argument("--diff", action="store_true", help="Show diff instead of writing.")
    format_parser.add_argument("--exclude", action="append", default=[], help="Exclude files matching this pattern.")
    format_parser.set_defaults(func=format_command)

    # Lint command
    lint_parser = subparsers.add_parser("lint", help="Lint Markdown files.")
    lint_parser.add_argument("path", nargs="+", help="Files or glob patterns to lint.")
    lint_parser.add_argument("--max-heading-level", type=int, help="Maximum heading level.")
    lint_parser.add_argument("--allow-html", action="store_true", help="Allow raw HTML.")
    lint_parser.add_argument("--format", choices=["text", "json"], default="text", help="Output format.")
    lint_parser.add_argument("--exclude", action="append", default=[], help="Exclude files matching this pattern.")
    lint_parser.set_defaults(func=lint_command)

    # Config command
    config_parser = subparsers.add_parser("config", help="Show or locate the configuration.")
    config_parser.add_argument("--show", action="store_true", help="Show the effective config.")
    config_parser.add_argument("--path", action="store_true", help="Show the config file location.")
    config_parser.set_defaults(func=config_command)

    args = parser.parse_args()

    if args.version:
        print(f"tidy {__version__}")
        return 0

    if args.verbose:
        print(f"Running with args: {args}")

    try:
        return args.func(args)
    except Exception as e:
        if args.verbose:
            raise
        print(f"Error: {e}", file=sys.stderr)
        return 2

if __name__ == "__main__":
    sys.exit(main())
