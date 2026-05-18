#!/usr/bin/env python3
"""
Fetch a Jira issue (and any linked Confluence pages) and emit a Markdown summary.

Usage:
  jira-fetch.py <ISSUE_KEY> [--out <path>]

Reads credentials from environment:
  CR_JIRA_BASE_URL, CR_JIRA_EMAIL, CR_JIRA_API_TOKEN

Stdlib-only (no pip deps required). HTML is converted to plain Markdown via a
minimal HTMLParser. Output is best-effort — if the API returns nothing useful,
the script writes a short note rather than crashing.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

CONFLUENCE_LINK_RE = re.compile(r"https?://[^\s\"'>)]+/wiki/[^\s\"'>)]+")


def auth_header(email: str, token: str) -> str:
    raw = f"{email}:{token}".encode("utf-8")
    return "Basic " + base64.b64encode(raw).decode("ascii")


def http_get_json(url: str, email: str, token: str, timeout: int = 30) -> dict | None:
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "Authorization": auth_header(email, token),
            "User-Agent": "code-reviewer/0.1",
        },
    )
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return json.loads(body)
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"[jira-fetch] HTTP {e.code} on {url}\n")
        return None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        sys.stderr.write(f"[jira-fetch] {type(e).__name__}: {e}\n")
        return None


class _HTMLToMarkdown(HTMLParser):
    """Minimal HTML -> Markdown converter for Jira/Confluence ADF-rendered HTML."""

    BLOCK_TAGS = {"p", "div", "section", "article", "li", "tr", "br", "pre"}
    HEADING_TAGS = {f"h{i}": i for i in range(1, 7)}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.out: list[str] = []
        self._list_stack: list[str] = []
        self._in_pre = False
        self._href_stack: list[str | None] = []

    def handle_starttag(self, tag, attrs):
        attrs_d = dict(attrs)
        if tag in self.HEADING_TAGS:
            self.out.append("\n\n" + "#" * self.HEADING_TAGS[tag] + " ")
        elif tag == "p":
            self.out.append("\n\n")
        elif tag == "br":
            self.out.append("\n")
        elif tag == "ul":
            self._list_stack.append("ul")
        elif tag == "ol":
            self._list_stack.append("ol")
        elif tag == "li":
            marker = "- " if (self._list_stack and self._list_stack[-1] == "ul") else "1. "
            self.out.append("\n" + "  " * max(0, len(self._list_stack) - 1) + marker)
        elif tag in ("strong", "b"):
            self.out.append("**")
        elif tag in ("em", "i"):
            self.out.append("*")
        elif tag == "code":
            self.out.append("`")
        elif tag == "pre":
            self._in_pre = True
            self.out.append("\n\n```\n")
        elif tag == "a":
            self._href_stack.append(attrs_d.get("href"))
            self.out.append("[")
        elif tag in ("hr",):
            self.out.append("\n\n---\n\n")

    def handle_endtag(self, tag):
        if tag in self.HEADING_TAGS:
            self.out.append("\n")
        elif tag in ("strong", "b"):
            self.out.append("**")
        elif tag in ("em", "i"):
            self.out.append("*")
        elif tag == "code":
            self.out.append("`")
        elif tag == "pre":
            self._in_pre = False
            self.out.append("\n```\n")
        elif tag in ("ul", "ol"):
            if self._list_stack:
                self._list_stack.pop()
        elif tag == "a":
            href = self._href_stack.pop() if self._href_stack else None
            if href:
                self.out.append(f"]({href})")
            else:
                self.out.append("]")

    def handle_data(self, data):
        if self._in_pre:
            self.out.append(data)
        else:
            self.out.append(re.sub(r"\s+", " ", data))

    def get_markdown(self) -> str:
        text = "".join(self.out)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text.strip()


def html_to_markdown(html: str) -> str:
    if not html:
        return ""
    parser = _HTMLToMarkdown()
    try:
        parser.feed(html)
    except Exception as e:  # noqa: BLE001 - best-effort fallback
        sys.stderr.write(f"[jira-fetch] HTML parse error: {e}\n")
        return re.sub(r"<[^>]+>", "", html)
    return parser.get_markdown()


def render_adf(node) -> str:
    """Very small ADF (Atlassian Document Format) -> Markdown renderer.

    Jira sometimes returns description in ADF JSON instead of HTML. Render what
    we can; fall back to JSON for unknown node types so nothing is silently
    dropped.
    """
    if node is None:
        return ""
    if isinstance(node, list):
        return "".join(render_adf(n) for n in node)
    if not isinstance(node, dict):
        return str(node)

    t = node.get("type")
    content = node.get("content")
    text = node.get("text", "")

    if t == "doc":
        return render_adf(content)
    if t == "paragraph":
        return render_adf(content) + "\n\n"
    if t == "heading":
        level = node.get("attrs", {}).get("level", 1)
        return "#" * level + " " + render_adf(content) + "\n\n"
    if t == "bulletList":
        return render_adf(content) + "\n"
    if t == "orderedList":
        return render_adf(content) + "\n"
    if t == "listItem":
        return "- " + render_adf(content).rstrip() + "\n"
    if t == "codeBlock":
        lang = node.get("attrs", {}).get("language", "")
        return f"\n```{lang}\n{render_adf(content)}\n```\n"
    if t == "hardBreak":
        return "\n"
    if t == "text":
        marks = node.get("marks") or []
        out = text
        for m in marks:
            mt = m.get("type")
            if mt == "strong":
                out = f"**{out}**"
            elif mt == "em":
                out = f"*{out}*"
            elif mt == "code":
                out = f"`{out}`"
            elif mt == "link":
                href = m.get("attrs", {}).get("href", "")
                out = f"[{out}]({href})"
        return out
    if t == "inlineCard":
        return node.get("attrs", {}).get("url", "")
    return render_adf(content)


def fetch_issue(base_url: str, key: str, email: str, token: str) -> dict | None:
    url = f"{base_url.rstrip('/')}/rest/api/3/issue/{urllib.parse.quote(key)}?expand=renderedFields"
    return http_get_json(url, email, token)


def fetch_confluence_page(page_url: str, email: str, token: str) -> str | None:
    m = re.search(r"/wiki/(?:spaces/[^/]+/)?pages/(\d+)", page_url)
    if not m:
        return None
    base = page_url.split("/wiki/")[0]
    page_id = m.group(1)
    api = f"{base}/wiki/api/v2/pages/{page_id}?body-format=storage"
    data = http_get_json(api, email, token)
    if not data:
        return None
    title = data.get("title", page_id)
    storage = (data.get("body", {}) or {}).get("storage", {}).get("value", "")
    md = html_to_markdown(storage)
    return f"### Confluence: {title}\n\nSource: {page_url}\n\n{md}\n"


def render_issue_markdown(issue: dict, base_url: str, email: str, token: str) -> str:
    fields = issue.get("fields", {}) or {}
    rendered = issue.get("renderedFields", {}) or {}
    key = issue.get("key", "")
    summary = fields.get("summary", "")
    status = (fields.get("status") or {}).get("name", "")
    issue_type = (fields.get("issuetype") or {}).get("name", "")
    priority = (fields.get("priority") or {}).get("name", "")
    assignee = (fields.get("assignee") or {}).get("displayName", "")
    reporter = (fields.get("reporter") or {}).get("displayName", "")

    desc_html = rendered.get("description") or ""
    if desc_html:
        description_md = html_to_markdown(desc_html)
    else:
        description_md = render_adf(fields.get("description")).strip()

    parts = [
        f"# Jira: {key} — {summary}",
        "",
        f"**Type:** {issue_type} · **Status:** {status} · **Priority:** {priority}",
        f"**Assignee:** {assignee} · **Reporter:** {reporter}",
        f"**URL:** {base_url.rstrip('/')}/browse/{key}",
        "",
        "## Description",
        "",
        description_md or "_(no description)_",
        "",
    ]

    comments = (fields.get("comment") or {}).get("comments") or []
    if comments:
        parts.append("## Comments")
        parts.append("")
        for c in comments[-10:]:
            author = (c.get("author") or {}).get("displayName", "")
            body_html = (rendered.get("comment") or {}).get("comments") or []
            md_body = ""
            for rc in body_html:
                if rc.get("id") == c.get("id"):
                    md_body = html_to_markdown(rc.get("body", ""))
                    break
            if not md_body:
                md_body = render_adf(c.get("body")).strip()
            parts.append(f"**{author}:**\n\n{md_body}\n")

    confluence_urls = set(CONFLUENCE_LINK_RE.findall(desc_html))
    for c in comments:
        body_html = render_adf(c.get("body"))
        confluence_urls.update(CONFLUENCE_LINK_RE.findall(body_html))

    if confluence_urls:
        parts.append("\n## Linked Confluence Pages\n")
        for url in sorted(confluence_urls):
            md = fetch_confluence_page(url, email, token)
            if md:
                parts.append(md)
            else:
                parts.append(f"- Could not fetch {url}\n")

    return "\n".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch a Jira issue as Markdown.")
    parser.add_argument("key", help="Jira issue key, e.g. ABC-123")
    parser.add_argument("--out", help="Write markdown to this path instead of stdout")
    args = parser.parse_args()

    base_url = os.environ.get("CR_JIRA_BASE_URL", "").strip()
    email = os.environ.get("CR_JIRA_EMAIL", "").strip()
    token = os.environ.get("CR_JIRA_API_TOKEN", "").strip()

    if not (base_url and email and token):
        sys.stderr.write(
            "[jira-fetch] Missing CR_JIRA_BASE_URL / CR_JIRA_EMAIL / CR_JIRA_API_TOKEN.\n"
        )
        return 2

    issue = fetch_issue(base_url, args.key, email, token)
    if issue is None:
        msg = f"# Jira: {args.key}\n\n_(could not fetch — see stderr)_\n"
    else:
        msg = render_issue_markdown(issue, base_url, email, token)

    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(msg)
        print(args.out)
    else:
        sys.stdout.write(msg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
