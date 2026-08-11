const panel = document.getElementById('panel');
const list = document.getElementById('stops');
const here = document.getElementById('here');
const roomTag = document.getElementById('roomTag');
const roomNum = document.getElementById('roomNum');

let stops = [];
let index = 0;
let open = false;

function post(name, data) {
  fetch(`https://${GetParentResourceName()}/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(data || {}),
  }).catch(() => {});
}

function render() {
  list.innerHTML = '';
  stops.forEach((s, i) => {
    const li = document.createElement('li');
    if (s.current) li.classList.add('here');
    if (s.mine) li.classList.add('mine');
    if (i === index && !s.current) li.classList.add('sel');

    const badge = document.createElement('div');
    badge.className = 'badge';
    badge.textContent = s.badge;

    const text = document.createElement('div');
    text.className = 'text';
    const name = document.createElement('div');
    name.className = 'name';
    name.textContent = s.label;
    text.appendChild(name);
    if (s.sub) {
      const sub = document.createElement('div');
      sub.className = 'sub';
      sub.textContent = s.sub;
      text.appendChild(sub);
    }

    li.appendChild(badge);
    li.appendChild(text);
    if (s.mine) {
      const dot = document.createElement('div');
      dot.className = 'dot';
      li.appendChild(dot);
    }

    li.addEventListener('click', () => { if (!s.current) choose(i); });
    li.addEventListener('mouseenter', () => { if (!s.current) { index = i; render(); } });
    list.appendChild(li);
  });
}

function move(step) {
  if (!stops.length) return;
  let i = index;
  for (let n = 0; n < stops.length; n++) {
    i = (i + step + stops.length) % stops.length;
    if (!stops[i].current) break;
  }
  index = i;
  render();
  const el = list.children[index];
  if (el) el.scrollIntoView({ block: 'nearest' });
}

// Mouse click and Enter both land here. Only ONE post goes out ('select') —
// the Lua side clears NUI focus, so posting 'close' too would race it.
function choose(i) {
  const s = stops[i];
  if (!s || s.current) return;
  open = false;
  panel.classList.add('hidden');
  post('select', { id: s.id });
}

function close() {
  open = false;
  panel.classList.add('hidden');
  post('close');
}

window.addEventListener('message', (e) => {
  const d = e.data || {};
  if (d.action !== 'open') {
    if (d.action === 'close') close();
    return;
  }
  stops = d.stops || [];
  here.textContent = d.hereLabel || '';
  if (d.room) {
    roomNum.textContent = d.room;
    roomTag.classList.remove('hidden');
  } else {
    roomTag.classList.add('hidden');
  }
  index = stops.findIndex((s) => s.mine && !s.current);
  if (index < 0) index = stops.findIndex((s) => !s.current);
  if (index < 0) index = 0;
  open = true;
  panel.classList.remove('hidden');
  render();
});

document.addEventListener('keydown', (e) => {
  if (!open) return;
  if (e.key === 'Escape' || e.key === 'Backspace') { e.preventDefault(); close(); }
  else if (e.key === 'ArrowDown' || e.key === 's') { e.preventDefault(); move(1); }
  else if (e.key === 'ArrowUp' || e.key === 'w') { e.preventDefault(); move(-1); }
  else if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); choose(index); }
});
