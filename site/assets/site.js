// The site works without this file. It adds the theme buttons on the live dock,
// the tour's autoplay, search, and copy buttons on commands.
(() => {
  'use strict';

  // The buttons above the hero's dock change its theme.
  const frame = document.getElementById('live-dock');
  const chips = document.querySelector('.hero-themes');
  if (frame && chips) {
    const dock = () => {
      try { return frame.contentWindow.mardockPlayground; } catch { return null; }
    };
    // They sit above the frame, so they step aside for the dock's own menus.
    const toggle = (event) => { chips.hidden = event.detail; };
    const ready = () => {
      if (!dock()) return;
      chips.hidden = false;
      frame.contentWindow.addEventListener('mardock-menu', toggle);
    };
    frame.addEventListener('load', ready);
    ready();
    chips.querySelectorAll('button').forEach((button) => {
      if (!button.hasAttribute('aria-pressed')) button.setAttribute('aria-pressed', 'false');
    });
    chips.addEventListener('click', (event) => {
      const button = event.target.closest('button');
      if (!button) return;
      chips.querySelectorAll('button').forEach((other) => other.setAttribute('aria-pressed', String(other === button)));
      dock()?.setSetting('theme', button.dataset.theme);
    });
  }

  // The tour plays while it's on screen, unless the visitor prefers stillness.
  const tour = document.getElementById('tour');
  if (tour && 'IntersectionObserver' in window && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
    let stopped = false;
    tour.addEventListener('pause', () => { if (tour.dataset.auto !== 'pause') stopped = true; });
    new IntersectionObserver(([entry]) => {
      if (stopped) return;
      if (entry.isIntersecting) {
        tour.play().catch(() => {});
      } else if (!tour.paused) {
        tour.dataset.auto = 'pause';
        tour.pause();
        delete tour.dataset.auto;
      }
    }, { threshold: 0.4 }).observe(tour);
  }

  // On a phone the topics start folded, so the page comes first.
  const menu = document.querySelector('.rail-menu');
  if (menu && matchMedia('(max-width: 760px)').matches) menu.open = false;

  // Commands get a copy button.
  document.querySelectorAll('.doc pre').forEach((block) => {
    if (!navigator.clipboard) return;
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'copy';
    button.textContent = 'Copy';
    button.addEventListener('click', async () => {
      await navigator.clipboard.writeText(block.querySelector('code').textContent);
      button.textContent = 'Copied';
      setTimeout(() => { button.textContent = 'Copy'; }, 1400);
    });
    block.append(button);
  });

  // The table of contents follows the reading position.
  const links = [...document.querySelectorAll('.toc a')];
  if (links.length && 'IntersectionObserver' in window) {
    const byId = new Map(links.map((link) => [decodeURIComponent(link.hash.slice(1)), link]));
    const watcher = new IntersectionObserver((entries) => {
      const seen = entries.find((entry) => entry.isIntersecting);
      if (!seen) return;
      links.forEach((link) => link.removeAttribute('aria-current'));
      byId.get(seen.target.id)?.setAttribute('aria-current', 'true');
    }, { rootMargin: '-48px 0px -70% 0px' });
    document.querySelectorAll('.doc h2[id]').forEach((heading) => watcher.observe(heading));
  }

  // Search reads one small index, from this site, the first time it's used.
  const input = document.getElementById('search');
  const results = document.getElementById('search-results');
  if (!input || !results) return;
  let index = null;
  let selected = -1;

  const load = async () => {
    if (index) return;
    try {
      index = await (await fetch('/search.json')).json();
    } catch {
      index = [];
    }
  };

  const score = (entry, words) => {
    const page = entry.page.toLowerCase();
    const heading = entry.heading.toLowerCase();
    const text = entry.text.toLowerCase();
    let total = 0;
    for (const word of words) {
      if (heading.includes(word)) total += 6;
      else if (page.includes(word)) total += 4;
      else if (text.includes(word)) total += 1;
      else return 0;
    }
    return total + (entry.heading ? 0 : 1);
  };

  const row = (entry) => {
    const item = document.createElement('li');
    const link = document.createElement('a');
    link.href = entry.url;
    link.textContent = entry.heading || entry.page;
    const place = document.createElement('small');
    place.textContent = entry.heading ? entry.page : 'Page';
    link.append(place);
    item.append(link);
    return item;
  };

  const render = () => {
    const words = input.value.toLowerCase().split(/\s+/).filter(Boolean);
    results.replaceChildren();
    selected = -1;
    if (!words.length || !index) {
      results.hidden = true;
      return;
    }
    const found = index
      .map((entry) => [score(entry, words), entry])
      .filter(([points]) => points > 0)
      .sort((a, b) => b[0] - a[0])
      .slice(0, 7);
    if (found.length) {
      results.append(...found.map(([, entry]) => row(entry)));
    } else {
      const none = document.createElement('li');
      none.className = 'none';
      none.textContent = `Nothing matches “${input.value.trim()}”.`;
      results.append(none);
    }
    results.hidden = false;
  };

  const select = (next) => {
    const options = [...results.querySelectorAll('a')];
    if (!options.length) return;
    selected = (next + options.length) % options.length;
    options.forEach((option, i) => option.setAttribute('aria-selected', String(i === selected)));
    options[selected].scrollIntoView({ block: 'nearest' });
  };

  input.addEventListener('focus', load);
  input.addEventListener('input', async () => {
    await load();
    render();
  });
  input.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      select(selected + 1);
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      select(selected - 1);
    } else if (event.key === 'Enter') {
      const options = results.querySelectorAll('a');
      const target = options[Math.max(selected, 0)];
      if (target) location.href = target.href;
    } else if (event.key === 'Escape') {
      input.value = '';
      render();
    }
  });
  document.addEventListener('keydown', (event) => {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
      event.preventDefault();
      input.focus();
      input.select();
    }
  });
  document.addEventListener('click', (event) => {
    if (!event.target.closest('.search')) results.hidden = true;
  });
})();
