#!/usr/bin/env python3
"""Builds the docs site into site/_site.

Standard library only, like the rest of MarDock's tooling: no packages to
install, no lock file to keep. Run it with `python3 site/build.py`, then serve
site/_site with any static file server. .github/workflows/pages.yml does the
same on every push to main.

The site has three parts: the home page and docs pages, written as HTML
fragments here; the changelog, read from CHANGELOG.md; and the live demo, which
is playground/index.html itself, so it can't drift from the app's engine.
"""
import hashlib
import html
import json
import re
import shutil
from pathlib import Path

SITE = Path(__file__).resolve().parent
REPO = SITE.parent
OUT = SITE / "_site"
ORIGIN = "https://mardock.alirazakhan.me"
GITHUB = "https://github.com/ALIRAZA47/mardock"

# The sidebar, in order: (group, [(slug, title), ...]).
DOCS = [
    ("Start", [("install", "Install"), ("first-run", "First run"), ("everyday", "Everyday use")]),
    ("Make it yours", [
        ("themes", "Themes"),
        ("layout", "Layout and hiding"),
        ("apps", "Apps and profiles"),
        ("shortcuts", "Shortcuts"),
        ("extras", "Extras"),
    ]),
    ("Your Mac", [("macos-dock", "macOS Dock"), ("updates", "Updates and backups"), ("privacy", "Privacy and security")]),
    ("Help", [("troubleshooting", "Troubleshooting"), ("build", "Build from source")]),
]
COLORS = {
    "install": "#30B0C7", "first-run": "#34C759", "everyday": "#007AFF", "themes": "#FF2D55", "layout": "#007AFF",
    "apps": "#FF9500", "shortcuts": "#AF52DE", "extras": "#30B0C7", "macos-dock": "#5856D6", "updates": "#8E8E93",
    "privacy": "#34C759", "troubleshooting": "#FF9500", "build": "#8E8E93",
}


def release():
    """The newest version in CHANGELOG.md."""
    found = re.search(r"^## \[(\d+\.\d+\.\d+)\] - (\S+)", (REPO / "CHANGELOG.md").read_text(), re.M)
    if not found:
        raise SystemExit("CHANGELOG.md names no released version")
    return found.group(1), found.group(2)


VERSION, RELEASED = release()
DMG = f"{GITHUB}/releases/download/v{VERSION}/MarDock-{VERSION}.dmg"


def fill(text):
    return text.replace("{{version}}", VERSION).replace("{{dmg}}", DMG).replace("{{github}}", GITHUB)


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()[:10]


def front_matter(source):
    """Splits a fragment's leading <!-- key: value --> block from its body."""
    found = re.match(r"\s*<!--(.*?)-->\s*", source, re.S)
    if not found:
        raise SystemExit("a fragment has no front matter")
    meta = dict(line.split(":", 1) for line in found.group(1).strip().splitlines())
    return {k.strip(): v.strip() for k, v in meta.items()}, source[found.end():]


def slugify(text):
    return re.sub(r"[^a-z0-9]+", "-", html.unescape(re.sub(r"<[^>]+>", "", text)).lower()).strip("-")


def plain(fragment):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", fragment))).strip()


def with_heading_ids(body):
    """Gives each <h2> an id, and returns the body and its (id, title) list."""
    headings = []

    def add(match):
        title = match.group(2)
        anchor = re.search(r'id="([^"]+)"', match.group(1) or "")
        anchor = anchor.group(1) if anchor else slugify(title)
        headings.append((anchor, plain(title)))
        return f'<h2 id="{anchor}">{title}</h2>'

    return re.sub(r"<h2([^>]*)>(.*?)</h2>", add, body, flags=re.S), headings


def page(layout, *, path, title, description, body, classes):
    url = ORIGIN + path
    current = {"docs": "docs" in classes, "demo": "demo" in classes, "changelog": "changelog" in classes}
    text = (
        layout.replace("{{title}}", html.escape(title, quote=True))
        .replace("{{description}}", html.escape(description, quote=True))
        .replace("{{url}}", url)
        .replace("{{classes}}", classes)
        .replace("{{css}}", fingerprint(SITE / "assets" / "site.css"))
        .replace("{{js}}", fingerprint(SITE / "assets" / "site.js"))
        .replace("{{body}}", body)
    )
    for name, on in current.items():
        text = text.replace("{{current-%s}}" % name, ' aria-current="page"' if on else "")
    return fill(text)


def write(path, text):
    target = OUT / path.lstrip("/")
    if path.endswith("/"):
        target = target / "index.html"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)


def sidebar(current):
    groups = []
    for group, items in DOCS:
        links = []
        for slug, title in items:
            mark = ' aria-current="page"' if slug == current else ""
            links.append(
                f'<a href="/docs/{slug}/"{mark}><span class="dot" style="--dot:{COLORS[slug]}" aria-hidden="true"></span>{title}</a>'
            )
        groups.append(f'<nav aria-label="{group}"><h2>{group}</h2>{"".join(links)}</nav>')
    return (
        '<details class="rail-menu" open><summary>All topics</summary>'
        f'<div class="rail-groups">{"".join(groups)}</div></details>'
    )


def docs_window(*, rail_current, group, heading, body, toc, foot=""):
    toc_html = ""
    if toc:
        links = "".join(f'<a href="#{anchor}">{html.escape(title)}</a>' for anchor, title in toc)
        toc_html = f'<aside class="toc" aria-label="On this page"><h2>On this page</h2><nav>{links}</nav></aside>'
    return f"""<div class="desk"><div class="docs-win">
<aside class="rail" aria-label="Documentation">
<div class="lights" aria-hidden="true"><i></i><i></i><i></i></div>
<div class="search" role="search">
<label class="search-field"><svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="7" cy="7" r="5"/><path d="M11 11l3.5 3.5"/></svg><span class="sr">Search the docs</span><input id="search" type="search" placeholder="Search the docs" autocomplete="off" spellcheck="false"></label>
<ul id="search-results" class="results" hidden></ul>
</div>
{sidebar(rail_current)}
</aside>
<main id="content" class="doc"><article>
<p class="kicker">{group}</p>
<h1>{heading}</h1>
{body}
{foot}
</article></main>
{toc_html}
</div></div>"""


def build_docs(layout):
    index = []
    order = [(slug, title, group) for group, items in DOCS for slug, title in items]
    summaries = []
    for position, (slug, title, group) in enumerate(order):
        meta, body = front_matter(fill((SITE / "docs" / f"{slug}.html").read_text()))
        body, headings = with_heading_ids(body)
        summaries.append((slug, title, group, meta["summary"]))

        before = order[position - 1] if position else None
        after = order[position + 1] if position + 1 < len(order) else None
        pager = '<nav class="pager" aria-label="Previous and next">'
        pager += f'<a href="/docs/{before[0]}/"><small>Previous</small>{before[1]}</a>' if before else "<span></span>"
        pager += f'<a class="next" href="/docs/{after[0]}/"><small>Next</small>{after[1]}</a>' if after else "<span></span>"
        pager += "</nav>"

        write(f"/docs/{slug}/", page(
            layout,
            path=f"/docs/{slug}/",
            title=f"{meta['title']} · MarDock docs",
            description=meta["summary"],
            classes="docs",
            body=docs_window(rail_current=slug, group=group, heading=meta["title"], body=body, toc=headings, foot=pager),
        ))

        # Search finds sections, so a result lands on the right heading.
        parts = re.split(r'(<h2 id="[^"]+">.*?</h2>)', body, flags=re.S)
        index.append({"page": meta["title"], "heading": "", "url": f"/docs/{slug}/", "text": plain(parts[0])[:600]})
        for head, text in zip(parts[1::2], parts[2::2]):
            anchor = re.search(r'id="([^"]+)"', head).group(1)
            index.append({"page": meta["title"], "heading": plain(head), "url": f"/docs/{slug}/#{anchor}", "text": plain(text)[:600]})
    write("/search.json", json.dumps(index, ensure_ascii=False, separators=(",", ":")))

    cards = "".join(
        f'<a class="topic" href="/docs/{slug}/"><span class="dot" style="--dot:{COLORS[slug]}" aria-hidden="true"></span>'
        f"<strong>{title}</strong><span>{html.escape(summary)}</span></a>"
        for slug, title, _, summary in summaries
    )
    write("/docs/", page(
        layout,
        path="/docs/",
        title="Docs · MarDock",
        description="How to install MarDock, make it yours and keep it running.",
        classes="docs",
        body=docs_window(
            rail_current="",
            group="MarDock {{version}}",
            heading="Documentation",
            body=f'<p class="lede">Everything MarDock does, and how to change it.</p><div class="topics">{cards}</div>',
            toc=[],
        ),
    ))


def inline_markdown(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*([^*]+)\*", r"<em>\1</em>", text)
    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)


def changelog_html():
    """CHANGELOG.md is written by hand in one small subset of Markdown."""
    source = (REPO / "CHANGELOG.md").read_text()
    links = dict(re.findall(r"^\[([^\]]+)\]: (\S+)$", source, re.M))
    source = re.sub(r"^\[[^\]]+\]: \S+\n?", "", source, flags=re.M)
    source = source[source.index(f"## [{VERSION}]"):]  # only what's been released

    blocks = []
    for block in re.split(r"\n\s*\n", source.strip()):
        lines = block.splitlines()
        if lines[0].startswith("## "):
            name, date = re.match(r"## \[([^\]]+)\] - (\S+)", lines[0]).groups()
            blocks.append(f'<h2 id="v{name.replace(".", "-")}"><a href="{links.get(name, "#")}">{name}</a> <small>{date}</small></h2>')
        elif lines[0].startswith("### "):
            blocks.append(f"<h3>{inline_markdown(lines[0][4:])}</h3>")
        elif lines[0].startswith("- "):
            items, current = [], []
            for line in lines:
                if line.startswith("- "):
                    if current:
                        items.append(" ".join(current))
                    current = [line[2:]]
                else:
                    current.append(line.strip())
            items.append(" ".join(current))
            blocks.append("<ul>" + "".join(f"<li>{inline_markdown(item)}</li>" for item in items) + "</ul>")
    return "\n".join(blocks)


def build_changelog(layout):
    body, headings = with_heading_ids_keeping_links(changelog_html())
    write("/changelog/", page(
        layout,
        path="/changelog/",
        title="Changelog · MarDock",
        description="What changed in each version of MarDock.",
        classes="docs changelog",
        body=docs_window(rail_current="", group="MarDock", heading="Changelog", body=body, toc=headings),
    ))


def with_heading_ids_keeping_links(body):
    headings = [
        (anchor, plain(title).split(" ")[0])
        for anchor, title in re.findall(r'<h2 id="([^"]+)">(.*?)</h2>', body, flags=re.S)
    ]
    return body, headings


def sitemap():
    paths = ["/", "/demo/", "/docs/", "/changelog/"]
    paths += [f"/docs/{slug}/" for _, items in DOCS for slug, _ in items]
    urls = "".join(f"<url><loc>{ORIGIN}{path}</loc></url>" for path in paths)
    write("/sitemap.xml", f'<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">{urls}</urlset>\n')
    write("/robots.txt", f"User-agent: *\nDisallow: /playground/\nSitemap: {ORIGIN}/sitemap.xml\n")


def main():
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir()
    shutil.copytree(SITE / "assets", OUT / "assets")

    # The demo is the playground itself.
    (OUT / "playground").mkdir()
    shutil.copy(REPO / "playground" / "index.html", OUT / "playground" / "index.html")

    layout = (SITE / "layout.html").read_text()
    meta, body = front_matter((SITE / "home.html").read_text())
    write("/", page(layout, path="/", title=meta["title"], description=meta["summary"], classes="home", body=body))
    meta, body = front_matter((SITE / "demo.html").read_text())
    write("/demo/", page(layout, path="/demo/", title=meta["title"], description=meta["summary"], classes="demo", body=body))
    meta, body = front_matter((SITE / "404.html").read_text())
    write("/404.html", page(layout, path="/404.html", title=meta["title"], description=meta["summary"], classes="lost", body=body))

    build_docs(layout)
    build_changelog(layout)
    sitemap()

    # Every page's internal links have to land somewhere.
    broken = []
    for built in OUT.rglob("*.html"):
        if built.parent.name == "playground":
            continue
        text = built.read_text()
        for link, anchor in re.findall(r'(?:href|src)="(/[^"#?]*)(?:\?[^"#]*)?(?:#([^"]*))?"', text):
            target = OUT / link.lstrip("/")
            if target.is_dir():
                target /= "index.html"
            if not target.is_file():
                broken.append(f"{built.relative_to(OUT)} -> {link}")
            elif anchor and f'id="{anchor}"' not in target.read_text():
                broken.append(f"{built.relative_to(OUT)} -> {link}#{anchor}")
        for anchor in re.findall(r'href="#([^"]+)"', text):
            if f'id="{anchor}"' not in text:
                broken.append(f"{built.relative_to(OUT)} -> #{anchor}")
    if broken:
        raise SystemExit("Broken links:\n  " + "\n  ".join(sorted(set(broken))))
    print(f"Built MarDock {VERSION} docs: {sum(1 for _ in OUT.rglob('*.html'))} pages in {OUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()
