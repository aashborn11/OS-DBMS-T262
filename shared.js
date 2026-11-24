/* Guild Press shared helpers: API calls, formatting, toast, generated T-shirt artwork. */
(function () {
  const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

  async function api(path, body) {
    const res = await fetch(path, body === undefined ? {} : {
      method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body) });
    const data = await res.json().catch(() => ({error: 'Unexpected response.'}));
    if (!res.ok) { const e = new Error(data.error || 'Something went wrong.'); e.status = res.status; throw e; }
    return data;
  }

  let toastTimer = null;
  function toast(msg, isError) {
    const t = document.getElementById('toast');
    if (!t) return;
    t.textContent = msg;
    t.className = 'show' + (isError ? ' error' : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.className = '', 3600);
  }

  const money = n => '₹' + Number(n).toLocaleString('en-IN', {maximumFractionDigits: 2});
  const fmtTime = ts => new Date(ts * 1000).toLocaleString([], {day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit'});

  /* Each design gets its own shirt: colours and graphic come from its title, so a design always looks the same. */
  const PALETTES = [
    ['#e8553d', '#fff1d6', '#27235c'], ['#3b82f6', '#ffffff', '#14213d'], ['#1f9d74', '#fff6d6', '#0f2f25'],
    ['#f5b82e', '#27235c', '#ffffff'], ['#8b5cf6', '#ffe4f1', '#ffffff'], ['#1f1f24', '#f5b82e', '#e8553d'],
    ['#ec7fa0', '#ffffff', '#4a1d3a'], ['#3f3d9a', '#ffd36a', '#ffffff'], ['#d8d2c4', '#27235c', '#e8553d'],
  ];
  function hash(str) { let h = 2166136261; for (const c of String(str)) { h ^= c.charCodeAt(0); h = Math.imul(h, 16777619); } return h >>> 0; }

  function tee(title, id) {
    const h = hash(title + ':' + id), [shirt, art, ink] = PALETTES[h % PALETTES.length];
    const kind = (h >> 4) % 4;
    const initials = String(title).trim().split(/\s+/).slice(0, 2).map(w => w[0]).join('').toUpperCase();
    let g = '';
    if (kind === 0) g = `<circle cx="100" cy="100" r="33" fill="${art}"/><circle cx="100" cy="100" r="21" fill="${ink}"/><text x="100" y="107" text-anchor="middle" font-family="system-ui,sans-serif" font-weight="800" font-size="19" fill="${art}">${esc(initials)}</text>`;
    else if (kind === 1) g = `<path d="M100 62l36 62H64z" fill="${art}"/><path d="M100 86l17 30H83z" fill="${ink}"/>`;
    else if (kind === 2) g = `<rect x="68" y="68" width="64" height="11" rx="5.5" fill="${art}"/><rect x="68" y="88" width="64" height="11" rx="5.5" fill="${ink}"/><rect x="68" y="108" width="64" height="11" rx="5.5" fill="${art}"/>`;
    else g = `<path d="M70 120c0-30 14-50 30-50s30 20 30 50z" fill="${art}"/><circle cx="100" cy="88" r="9" fill="${ink}"/><rect x="68" y="124" width="64" height="7" rx="3.5" fill="${ink}"/>`;
    return `<svg viewBox="0 0 200 200" role="img" aria-label="${esc(title)} tee">
      <path d="M70 20L40 32 12 70l26 18 14-14v106h96V74l14 14 26-18-28-38-30-12c-6 14-54 14-60 0z" fill="${shirt}"/>
      <path d="M52 74v106h34c-8-30-6-70 4-96z" fill="#fff" opacity=".07"/>
      <path d="M148 74v106h-26c10-34 10-72 0-100z" fill="#000" opacity=".07"/>
      <path d="M70 20c6 14 54 14 60 0" fill="none" stroke="#000" stroke-opacity=".25" stroke-width="4"/>
      <path d="M52 74l-14 14M148 74l14 14" stroke="#000" stroke-opacity=".12" stroke-width="2"/>
      ${g}</svg>`;
  }
  const tint = (title, id) => `color-mix(in srgb, ${PALETTES[hash(title + ':' + id) % PALETTES.length][0]} 16%, var(--bg2))`;

  window.GP = {esc, api, toast, money, fmtTime, tee, tint, hash};
})();
