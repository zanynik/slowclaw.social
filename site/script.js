document.addEventListener('DOMContentLoaded', () => {
  // ── Animated "run feed" inside the hero terminal ──────────────────────────
  const runFeed = document.getElementById('runFeed');

  const ops = [
    { label: '[DRAFT]', action: 'Distilled 3 social posts from "Morning reflection"', time: 'just now', color: '#2E9473' },
    { label: '[TASKS]', action: 'Extracted 2 follow-ups into your todo list', time: 'just now', color: '#6fbfa3' },
    { label: '[FEED]', action: 'Ranked 5 Bluesky + Nostr posts against your interests', time: 'processing', color: '#E35335' },
    { label: '[PRIVACY]', action: '0 bytes uploaded · inference stayed on-device', time: 'always', color: '#FFBD2E' },
  ];

  if (runFeed) {
    ops.forEach((op, i) => {
      setTimeout(() => {
        const row = document.createElement('div');
        row.className = 'run-item';
        row.innerHTML = `
          <div class="header">
            <strong style="color: ${op.color}">${op.label}</strong>
            <small>${op.time}</small>
          </div>
          <span>${op.action}</span>
        `;
        runFeed.appendChild(row);
      }, 900 + i * 1400);
    });
  }

  // ── Reveal-on-scroll ──────────────────────────────────────────────────────
  const reveals = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.15, rootMargin: '0px 0px -50px 0px' });

    reveals.forEach((el, idx) => {
      el.style.transitionDelay = `${(idx % 3) * 100}ms`;
      io.observe(el);
    });
  } else {
    reveals.forEach((el) => el.classList.add('is-visible'));
  }

  // ── Smooth scroll for in-page anchors ────────────────────────────────────
  document.querySelectorAll('a[href^="#"]').forEach((anchor) => {
    anchor.addEventListener('click', function (e) {
      const href = this.getAttribute('href');
      if (!href || href === '#') return;
      const target = document.querySelector(href);
      if (target) {
        e.preventDefault();
        target.scrollIntoView({ behavior: 'smooth' });
        // Close the mobile drawer if open after navigating.
        closeDrawer();
      }
    });
  });

  // ── Header nudge on scroll ────────────────────────────────────────────────
  const header = document.querySelector('.site-header');
  const onScroll = () => {
    if (!header) return;
    header.style.transform = window.scrollY > 50 ? 'translateY(-0.5rem)' : 'translateY(0)';
  };
  window.addEventListener('scroll', onScroll, { passive: true });

  // ── Mobile burger menu ────────────────────────────────────────────────────
  const burger = document.getElementById('navBurger');
  const drawer = document.getElementById('navDrawer');

  function closeDrawer() {
    if (!burger || !drawer) return;
    burger.classList.remove('is-open');
    burger.setAttribute('aria-expanded', 'false');
    drawer.hidden = true;
  }

  function openDrawer() {
    if (!burger || !drawer) return;
    burger.classList.add('is-open');
    burger.setAttribute('aria-expanded', 'true');
    drawer.hidden = false;
  }

  if (burger && drawer) {
    burger.addEventListener('click', () => {
      drawer.hidden ? openDrawer() : closeDrawer();
    });
    // Close when clicking outside the header.
    document.addEventListener('click', (e) => {
      if (drawer.hidden) return;
      if (!e.target.closest('.site-header')) closeDrawer();
    });
    // Close on Escape.
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') closeDrawer();
    });
  }
});
