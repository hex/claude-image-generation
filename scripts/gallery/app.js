'use strict';

// Renders the server's snapshot of image runs, newest first. Every value from a run goes into the
// page as text (textContent) or as an attribute set through the DOM, never as HTML.

const list = document.getElementById('run-list');
const empty = document.getElementById('empty');
const connection = document.getElementById('connection');
const runNodes = new Map();
const timeFormat = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' });
const secondsFormat = new Intl.NumberFormat(undefined, { minimumFractionDigits: 1, maximumFractionDigits: 1 });
const onMac = /Mac/.test(navigator.platform);
const RUN_LABEL = { live: 'Running', done: 'Finished', interrupted: 'Interrupted' };

function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (key === 'class') node.className = value;
    else if (key === 'text') node.textContent = value;
    else node.setAttribute(key, value);
  }
  for (const child of children) if (child) node.append(child);
  return node;
}

function seconds(ms) {
  return /^[0-9]+$/.test(ms) ? secondsFormat.format(Number(ms) / 1000) + ' s' : '';
}

function startedAt(iso) {
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? iso : timeFormat.format(date);
}

function imageUrl(run, card) {
  return '/img/' + [run.id, card.name, String(card.image.n)].map(encodeURIComponent).join('/');
}

async function post(url, button, note) {
  button.disabled = true;
  button.setAttribute('aria-busy', 'true');
  note.textContent = '';
  try {
    const response = await fetch(url, { method: 'POST' });
    const answer = await response.json().catch(() => ({}));
    if (!response.ok) note.textContent = answer.error || 'The server answered ' + response.status + '.';
  } catch (error) {
    note.textContent = 'Could not reach the gallery server.';
  } finally {
    button.disabled = false;
    button.removeAttribute('aria-busy');
  }
}

function stateLine(card) {
  switch (card.state) {
    case 'complete': return ['Done', seconds(card.ms)].filter(Boolean).join(' · ');
    case 'querying': return card.round > 0 ? 'Generating again…' : 'Generating…';
    case 'retrying': return 'Retrying ' + card.attempt + '…';
    case 'error': return 'Failed';
    case 'interrupted': return 'Stopped';
    default: return 'Waiting…';
  }
}

function cardBody(run, card) {
  if (card.state === 'complete' && card.image) {
    const url = imageUrl(run, card);
    const image = el('img', { src: url, alt: card.name + ' image for: ' + run.prompt, loading: 'lazy', decoding: 'async' });
    const frame = el('a', { class: 'frame', href: url, target: '_blank', rel: 'noopener' }, image);
    image.onerror = () => frame.replaceWith(el('p', { class: 'placeholder missing', text: 'The image file was moved or deleted.' }));
    const note = el('span', { class: 'note', 'aria-live': 'polite' });
    const reveal = el('button', { type: 'button', 'data-key': 'reveal-' + card.name, text: onMac ? 'Show in Finder' : 'Show in folder' });
    reveal.onclick = () => post(url.replace('/img/', '/reveal/'), reveal, note);
    const file = card.image.path.split('/').pop();
    return [frame, el('div', { class: 'card-foot' }, el('span', { class: 'file', title: card.image.path, text: file }), reveal, note)];
  }
  if (card.state === 'error') {
    return [el('pre', { class: 'error-text', text: card.error || 'No error message was recorded.' })];
  }
  if (card.state === 'interrupted') {
    return [el('p', { class: 'placeholder', text: 'Stopped before an image arrived.' })];
  }
  return [el('p', { class: 'placeholder' }, el('span', { class: 'spinner', 'aria-hidden': 'true' }), el('span', { text: stateLine(card) }))];
}

function providerCard(run, card) {
  const head = el('div', { class: 'card-head' },
    el('span', { class: 'name', text: card.name }),
    card.model ? el('span', { class: 'model', title: card.model, text: card.model }) : null,
    ['complete', 'error', 'interrupted'].includes(card.state) ? el('span', { class: 'state', text: stateLine(card) }) : null);
  return el('li', { class: 'card provider-' + card.name + ' state-' + card.state }, head, ...cardBody(run, card));
}

function runCard(run) {
  const promptId = 'prompt-' + run.id;
  const meta = el('div', { class: 'run-meta' },
    el('span', { class: 'badge status-' + run.status, text: RUN_LABEL[run.status] || run.status }),
    el('time', { datetime: run.started_at, text: startedAt(run.started_at) }),
    run.cwd ? el('span', { class: 'cwd', title: run.cwd, text: run.cwd }) : null);
  const head = el('header', { class: 'run-head' }, el('p', { class: 'prompt', id: promptId, text: run.prompt || '(no prompt recorded)' }), meta);
  if (run.retry && run.retry.length) {
    const note = el('span', { class: 'note', 'aria-live': 'polite' });
    const button = el('button', { type: 'button', class: 'primary', 'data-key': 'retry', text: 'Retry ' + run.retry.join(', ') });
    button.onclick = () => post('/retry/' + encodeURIComponent(run.id), button, note);
    head.append(el('div', { class: 'retry' }, el('span', { text: run.retry.join(', ') + ' failed.' }), button, note));
  }
  if (run.problem) head.append(el('p', { class: 'problem', text: run.problem }));
  const cards = el('ul', { class: 'cards' }, ...run.providers.map(card => providerCard(run, card)));
  return el('li', { class: 'run' }, el('article', { 'aria-labelledby': promptId }, head, cards));
}

function render(snapshot) {
  const seen = new Set();
  let previous = null;
  for (const run of snapshot.runs) {
    seen.add(run.id);
    const key = JSON.stringify(run);
    let entry = runNodes.get(run.id);
    if (!entry || entry.key !== key) {
      const node = runCard(run);
      if (entry) {
        const focused = entry.node.contains(document.activeElement) && document.activeElement.dataset.key;
        entry.node.replaceWith(node);
        if (focused) {
          const again = node.querySelector('[data-key="' + CSS.escape(focused) + '"]');
          if (again) again.focus();
        }
      }
      entry = { key, node };
      runNodes.set(run.id, entry);
    }
    const slot = previous ? previous.nextSibling : list.firstChild;
    if (slot !== entry.node) list.insertBefore(entry.node, slot);
    previous = entry.node;
  }
  for (const [id, entry] of runNodes) {
    if (!seen.has(id)) {
      entry.node.remove();
      runNodes.delete(id);
    }
  }
  empty.hidden = snapshot.runs.length > 0;
  const live = snapshot.runs.filter(run => run.status === 'live').length;
  document.title = live ? '(' + live + ') Image gallery' : 'Image gallery';
}

function connect() {
  const source = new EventSource('/events');
  source.onopen = () => { connection.textContent = ''; };
  source.onmessage = event => render(JSON.parse(event.data));
  source.onerror = () => {
    if (source.readyState === EventSource.CLOSED) {
      connection.textContent = 'The gallery server turned this page away. Open the address the image tool printed, or start an image run.';
      setTimeout(connect, 5000);
    } else {
      connection.textContent = 'Reconnecting to the gallery server…';
    }
  };
}

connect();
