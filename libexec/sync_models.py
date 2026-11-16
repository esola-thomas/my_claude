#!/usr/bin/env python3
"""Synchronize LiteLLM and Claude Code model aliases with GitHub Copilot.

Writes a LiteLLM config, a models.env file, and a Claude Code settings file.
The catalog request uses client headers copied from VS Code Copilot Chat.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


CATALOG_URL = os.environ.get("MY_CLAUDE_CATALOG_URL", "https://api.githubcopilot.com/models")
EDITOR_VERSION = "vscode/1.95.0"
PREFERRED_PRIMARY = os.environ.get("MY_CLAUDE_PRIMARY", "")
REQUIRED = ("opus_latest", "sonnet_latest", "haiku_latest")


def version_key(model_id: str) -> tuple[int, ...]:
    numbers = re.findall(r"\d+", model_id)
    return tuple(int(number) for number in numbers)


def fetch_catalog(token_file: Path) -> list[dict[str, Any]]:
    token = token_file.read_text(encoding="utf-8").strip()
    if not token:
        raise RuntimeError(f"Copilot token file is empty: {token_file}")

    request = urllib.request.Request(
        CATALOG_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "Editor-Version": EDITOR_VERSION,
            "User-Agent": "GitHubCopilotChat/0.26.7",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"Copilot catalog returned HTTP {error.code}") from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"Could not reach Copilot catalog: {error.reason}") from error

    models = payload.get("data", payload.get("models", payload))
    if not isinstance(models, list):
        raise RuntimeError("Copilot catalog response did not contain a model list")
    return models


def is_enabled(model: dict[str, Any]) -> bool:
    state = (model.get("policy") or {}).get("state")
    return state == "enabled"


def latest(
    models: list[dict[str, Any]],
    pattern: str,
    *,
    exclude: tuple[str, ...] = (),
) -> dict[str, Any] | None:
    regex = re.compile(pattern)
    matches = [
        model
        for model in models
        if is_enabled(model)
        and regex.fullmatch(str(model.get("id", "")))
        and not any(part in str(model.get("id", "")) for part in exclude)
    ]
    return max(matches, key=lambda model: version_key(str(model["id"])), default=None)


def select_models(models: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    by_id = {str(model.get("id")): model for model in models if model.get("id")}
    opus_latest = latest(models, r"claude-opus-\d+(?:\.\d+)*")
    selections = {
        "opus_latest": opus_latest,
        "sonnet_latest": latest(models, r"claude-sonnet-\d+(?:\.\d+)*"),
        "haiku_latest": latest(models, r"claude-haiku-\d+(?:\.\d+)*"),
        "gpt_astra_latest": latest(models, r"gpt-\d+(?:\.\d+)*-astra"),
        "gpt_sol_latest": latest(
            models, r"gpt-\d+(?:\.\d+)*-sol", exclude=("-fast", "-utility")
        ),
        "gpt_luna_latest": latest(
            models, r"gpt-\d+(?:\.\d+)*-luna", exclude=("-fast", "-utility")
        ),
    }
    preferred = by_id.get(PREFERRED_PRIMARY)
    selections["opus_primary"] = (
        preferred if preferred and is_enabled(preferred) else opus_latest
    )

    missing = [name for name in REQUIRED if selections.get(name) is None]
    if missing:
        raise RuntimeError(
            "No enabled Copilot model found for: " + ", ".join(sorted(missing))
        )
    return {name: model for name, model in selections.items() if model is not None}


GPT_ALIASES = (
    ("gpt_astra_latest", "gpt-astra-latest"),
    ("gpt_sol_latest", "gpt-sol-latest"),
    ("gpt_luna_latest", "gpt-luna-latest"),
)


def model_limits(model: dict[str, Any]) -> tuple[int | None, int | None]:
    limits = ((model.get("capabilities") or {}).get("limits") or {})
    return (
        limits.get("max_context_window_tokens"),
        limits.get("max_output_tokens"),
    )


def claude_context_profile(model: dict[str, Any]) -> str:
    model_id = str(model["id"])
    max_context, _ = model_limits(model)
    if model_id.startswith("claude-") and max_context and max_context >= 1_000_000:
        return f"{model_id}[1m]"
    return model_id


def yaml_entry(alias: str, upstream: dict[str, Any]) -> list[str]:
    model_id = str(upstream["id"])
    max_input, max_output = model_limits(upstream)
    lines = [f"  - model_name: {alias}"]
    responses_only = bool(re.fullmatch(r"gpt-\d+(?:\.\d+)*-(?:astra|sol|luna)", model_id))
    if max_input or max_output or responses_only:
        lines.append("    model_info:")
        if responses_only:
            lines.append("      mode: responses")
        if max_input:
            lines.append(f"      max_input_tokens: {int(max_input)}")
        if max_output:
            lines.append(f"      max_output_tokens: {int(max_output)}")
    lines.extend(
        [
            "    litellm_params:",
            f"      model: github_copilot/{model_id}",
            "",
        ]
    )
    return lines


def render_managed_config(selections: dict[str, dict[str, Any]]) -> str:
    aliases: list[tuple[str, dict[str, Any]]] = [
        ("claude-opus-primary", selections["opus_primary"]),
        ("claude-opus-latest", selections["opus_latest"]),
        ("claude-sonnet-latest", selections["sonnet_latest"]),
        ("claude-haiku-latest", selections["haiku_latest"]),
    ]
    for key, alias in GPT_ALIASES:
        if key in selections:
            aliases.append((alias, selections[key]))

    selected_by_id: dict[str, dict[str, Any]] = {}
    for model in selections.values():
        selected_by_id[str(model["id"])] = model
    for model_id, model in sorted(selected_by_id.items()):
        aliases.extend(((model_id, model), (f"github_copilot/{model_id}", model)))

    seen: set[str] = set()
    lines = [
        "# Generated by sync_models.py. Manual edits are replaced on the next launch.",
        "general_settings:",
        "  master_key: os.environ/MY_CLAUDE_KEY",
        "",
        "litellm_settings:",
        "  drop_params: true",
        "",
        "model_list:",
    ]
    for alias, model in aliases:
        if alias in seen:
            continue
        seen.add(alias)
        lines.extend(yaml_entry(alias, model))

    fallbacks = [
        ("claude-opus-primary", ["claude-sonnet-latest", "claude-haiku-latest"]),
        ("claude-sonnet-latest", ["claude-haiku-latest"]),
        ("gpt-astra-latest", ["gpt-sol-latest", "gpt-luna-latest"]),
        ("gpt-sol-latest", ["gpt-luna-latest"]),
    ]
    present = {alias for alias, _ in aliases}
    lines.extend(["router_settings:", "  num_retries: 1", "  fallbacks:"])
    for source, targets in fallbacks:
        kept = [t for t in targets if t in present]
        if source in present and kept:
            lines.append(f"    - {source}:")
            lines.extend(f"        - {t}" for t in kept)
    lines.append("")
    return "\n".join(lines)


def atomic_write(path: Path, content: str) -> bool:
    old_content = path.read_text(encoding="utf-8") if path.exists() else ""
    if old_content == content:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = 0o600
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, delete=False
    ) as temporary:
        temporary.write(content)
        temporary_path = Path(temporary.name)
    os.chmod(temporary_path, mode)
    temporary_path.replace(path)
    return True


def build_settings(selections: dict[str, dict[str, Any]]) -> dict[str, Any]:
    primary = str(selections["opus_primary"]["id"])
    sonnet = str(selections["sonnet_latest"]["id"])
    haiku = str(selections["haiku_latest"]["id"])
    primary_profile = claude_context_profile(selections["opus_primary"])
    opus_latest_profile = claude_context_profile(selections["opus_latest"])
    sonnet_profile = claude_context_profile(selections["sonnet_latest"])

    available = [primary_profile, opus_latest_profile, sonnet_profile, haiku]
    options = []
    aliases = {
        "haiku": haiku,
        "opus": primary_profile,
        "sonnet": sonnet_profile,
        "deep": primary_profile,
        "fast": sonnet_profile,
        "standard": primary_profile,
    }
    gpt_meta = {
        "gpt_astra_latest": ("astra", "GPT Astra", primary_profile,
                             "Highest-capability OpenAI model for complex implementation and review."),
        "gpt_sol_latest": ("sol", "GPT Sol", sonnet_profile,
                           "Balanced OpenAI model for everyday coding and agent work."),
        "gpt_luna_latest": ("luna", "GPT Luna", sonnet_profile,
                            "Fast, low-cost OpenAI model for lightweight and high-volume tasks."),
    }
    for key, alias in GPT_ALIASES:
        if key not in selections:
            continue
        short, label, behaves_as, description = gpt_meta[key]
        model_id = str(selections[key]["id"])
        available.extend([alias, model_id])
        aliases[short] = alias
        options.append(
            {
                "model": alias,
                "label": f"{label} - {model_id}",
                "description": description + " Via Copilot and LiteLLM.",
                "behavesAs": behaves_as,
            }
        )
    if "gpt_luna_latest" in selections:
        aliases["cheap"] = "gpt-luna-latest"

    settings: dict[str, Any] = {
        "availableModels": list(dict.fromkeys(available)),
        "modelAliases": aliases,
        "env": {
            "ANTHROPIC_MODEL": primary_profile,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": primary_profile,
            "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": f"{primary} (Copilot/LiteLLM)",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": sonnet_profile,
            "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": f"{sonnet} (Copilot/LiteLLM)",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": haiku,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": f"{haiku} (Copilot/LiteLLM)",
        },
    }
    if options:
        settings["modelPicker"] = {"replaceBuiltInOptions": False, "options": options}
    return settings


def update_claude_settings(path: Path, selections: dict[str, dict[str, Any]]) -> bool:
    content = json.dumps(build_settings(selections), indent=2, ensure_ascii=True) + "\n"
    return atomic_write(path, content)


def update_env_file(path: Path, selections: dict[str, dict[str, Any]]) -> bool:
    values = {
        "MY_CLAUDE_PRIMARY_MODEL": selections["opus_primary"]["id"],
        "MY_CLAUDE_PRIMARY_PROFILE": claude_context_profile(selections["opus_primary"]),
        "MY_CLAUDE_OPUS_MODEL": selections["opus_latest"]["id"],
        "MY_CLAUDE_SONNET_MODEL": selections["sonnet_latest"]["id"],
        "MY_CLAUDE_SONNET_PROFILE": claude_context_profile(selections["sonnet_latest"]),
        "MY_CLAUDE_HAIKU_MODEL": selections["haiku_latest"]["id"],
    }
    for key, name in (
        ("gpt_astra_latest", "MY_CLAUDE_GPT_ASTRA_MODEL"),
        ("gpt_sol_latest", "MY_CLAUDE_GPT_SOL_MODEL"),
        ("gpt_luna_latest", "MY_CLAUDE_GPT_LUNA_MODEL"),
    ):
        if key in selections:
            values[name] = selections[key]["id"]
    content = "\n".join(
        f"export {name}={shlex.quote(str(value))}" for name, value in values.items()
    )
    return atomic_write(path, content + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--settings-out", type=Path, required=True)
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument(
        "--token-file",
        type=Path,
        default=Path(
            os.environ.get("GITHUB_COPILOT_TOKEN_DIR")
            or Path.home() / ".config/litellm/github_copilot"
        )
        / os.environ.get("GITHUB_COPILOT_ACCESS_TOKEN_FILE", "access-token"),
    )
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    last_error: Exception | None = None
    selections: dict[str, dict[str, Any]] | None = None
    for attempt in range(3):
        try:
            selections = select_models(fetch_catalog(args.token_file))
            break
        except Exception as error:
            last_error = error
            if attempt < 2:
                time.sleep(attempt + 1)
    if selections is None:
        assert last_error is not None
        raise last_error
    summary = {name: model["id"] for name, model in selections.items()}

    if args.check:
        print("VERIFIED " + json.dumps(summary, sort_keys=True))
        return 0

    config_changed = atomic_write(args.config, render_managed_config(selections))
    settings_changed = update_claude_settings(args.settings_out, selections)
    env_changed = update_env_file(args.env_file, selections)
    status = "UPDATED" if config_changed or settings_changed or env_changed else "VERIFIED"
    print(f"{status} " + json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERROR {error}", file=sys.stderr)
        raise SystemExit(1)
