'use strict';

// The gallery as a contact sheet: one strip per image run, newest first, its providers' frames side
// by side. Every value from a run goes into the page as text (textContent) or as an attribute set
// through the DOM, never as HTML. Strips are kept by run id and frames by provider name, so a
// snapshot rebuilds only the parts that changed and an image already shown never reloads.

const SVG_NS = 'http://www.w3.org/2000/svg';
// Phosphor regular icons, the path data read out of @phosphor-icons/core 2.1.1 (assets/regular). The folder
// and the clock are the Agents sidebar's own marks, as its page draws them.
const ICONS = {
  'folder': 'M216,72H130.67L102.93,51.2a16.12,16.12,0,0,0-9.6-3.2H40A16,16,0,0,0,24,64V200a16,16,0,0,0,16,16H216.89A15.13,15.13,0,0,0,232,200.89V88A16,16,0,0,0,216,72ZM40,64H93.33l21.34,16L93.33,96H40ZM216,200H40V112H93.33a16.12,16.12,0,0,0,9.6-3.2L130.67,88H216Z',
  'clock': 'M128,24A104,104,0,1,0,232,128,104.11,104.11,0,0,0,128,24Zm0,192a88,88,0,1,1,88-88A88.1,88.1,0,0,1,128,216Zm64-88a8,8,0,0,1-8,8H128a8,8,0,0,1-8-8V72a8,8,0,0,1,16,0v48h48A8,8,0,0,1,192,128Z',
  'folder-open': 'M245,110.64A16,16,0,0,0,232,104H216V88a16,16,0,0,0-16-16H130.67L102.94,51.2a16.14,16.14,0,0,0-9.6-3.2H40A16,16,0,0,0,24,64V208h0a8,8,0,0,0,8,8H211.1a8,8,0,0,0,7.59-5.47l28.49-85.47A16.05,16.05,0,0,0,245,110.64ZM93.34,64,123.2,86.4A8,8,0,0,0,128,88h72v16H69.77a16,16,0,0,0-15.18,10.94L40,158.7V64Zm112,136H43.1l26.67-80H232Z',
  'arrows-out': 'M216,48V96a8,8,0,0,1-16,0V67.31l-42.34,42.35a8,8,0,0,1-11.32-11.32L188.69,56H160a8,8,0,0,1,0-16h48A8,8,0,0,1,216,48ZM98.34,146.34,56,188.69V160a8,8,0,0,0-16,0v48a8,8,0,0,0,8,8H96a8,8,0,0,0,0-16H67.31l42.35-42.34a8,8,0,0,0-11.32-11.32ZM208,152a8,8,0,0,0-8,8v28.69l-42.34-42.35a8,8,0,0,0-11.32,11.32L188.69,200H160a8,8,0,0,0,0,16h48a8,8,0,0,0,8-8V160A8,8,0,0,0,208,152ZM67.31,56H96a8,8,0,0,0,0-16H48a8,8,0,0,0-8,8V96a8,8,0,0,0,16,0V67.31l42.34,42.35a8,8,0,0,0,11.32-11.32Z',
  'arrow-clockwise': 'M240,56v48a8,8,0,0,1-8,8H184a8,8,0,0,1,0-16H211.4L184.81,71.64l-.25-.24a80,80,0,1,0-1.67,114.78,8,8,0,0,1,11,11.63A95.44,95.44,0,0,1,128,224h-1.32A96,96,0,1,1,195.75,60L224,85.8V56a8,8,0,1,1,16,0Z',
  'x': 'M205.66,194.34a8,8,0,0,1-11.32,11.32L128,139.31,61.66,205.66a8,8,0,0,1-11.32-11.32L116.69,128,50.34,61.66A8,8,0,0,1,61.66,50.34L128,116.69l66.34-66.35a8,8,0,0,1,11.32,11.32L139.31,128Z',
};

const stripList = document.getElementById('strip-list');
const empty = document.getElementById('empty');
const sessionList = document.getElementById('sessions');
const connection = document.getElementById('connection');
const fresh = document.getElementById('fresh');
const loupe = document.getElementById('loupe');
const loupeImage = document.getElementById('loupe-image');
const loupePrint = document.getElementById('loupe-print');
const loupeNote = document.getElementById('loupe-note');
const loupePrompt = document.getElementById('loupe-prompt');

const REVEAL_LABEL = /Mac/.test(navigator.platform) ? 'Reveal in Finder' : 'Show in folder';
const NO_RUNS = 'No image runs yet. Images from Claude Code show up here while they generate.';
const LOUPE_MS = 200;
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const clock = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const dayAndClock = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });

// run id -> { run, node, head, headKey, recency, frameList, frames: Map(provider -> { key, node }), roundSeen }
const strips = new Map();
let runs = [];
let railKey = '';
let unseen = 0;
let firstSnapshot = true;
let loupeAt = null;
let loupeClosing = 0;

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

function icon(name) {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 256 256');
  svg.setAttribute('fill', 'currentColor');
  svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS(SVG_NS, 'path');
  path.setAttribute('d', ICONS[name]);
  svg.append(path);
  return svg;
}

function seconds(ms) {
  return /^[0-9]+$/.test(ms) ? (Number(ms) / 1000).toFixed(1) + 's' : '';
}

// "now" and "4 min" within the hour, the clock within the day, then the date and the clock.
function relative(iso) {
  const at = new Date(iso);
  if (Number.isNaN(at.getTime())) return '';
  const minutes = Math.floor((Date.now() - at.getTime()) / 60000);
  if (minutes < 1) return 'now';
  if (minutes < 60) return minutes + ' min';
  if (minutes < 24 * 60) return clock.format(at);
  return dayAndClock.format(at);
}

// "Updated 10 s ago", from when a live run last moved, as the sidebar's recency line reads.
function updatedAgo(ms) {
  const seconds = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  const age = seconds < 60 ? seconds + ' s' : seconds < 3600 ? Math.floor(seconds / 60) + ' m' : Math.floor(seconds / 3600) + ' h';
  return 'Updated ' + age + ' ago';
}

function imageUrl(run, card) {
  return 'img/' + [run.id, card.name, String(card.image.n)].map(encodeURIComponent).join('/');
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

function revealButton(urlOf, note) {
  const button = el('button', { type: 'button', class: 'act', 'aria-label': REVEAL_LABEL, 'data-key': 'reveal' }, icon('folder-open'));
  button.addEventListener('click', () => post(urlOf().replace(/^img\//, 'reveal/'), button, note));
  return button;
}

function fullSizeLink(url) {
  return el('a', { class: 'act', href: url, target: '_blank', rel: 'noopener', 'aria-label': 'Open full size', 'data-key': 'full' }, icon('arrows-out'));
}

// ── Frames ───────────────────────────────────────────────────────

// The wait fill of a frame still at work, timed from when its round began: the run's start for the
// first round, the moment this page first saw a later one. No usual time, no fill.
function waitingPlate(run, card, frame) {
  if (!card.usual_ms) return [];
  const round = card.name + '/' + card.round;
  if (!frame.entry.roundSeen.has(round)) frame.entry.roundSeen.set(round, card.round > 0 ? Date.now() : Date.parse(run.started_at));
  const began = frame.entry.roundSeen.get(round);
  const elapsed = Number.isNaN(began) ? 0 : Math.max(0, Date.now() - began);
  const fill = el('span', { class: 'fill' });
  fill.style.setProperty('--usual', card.usual_ms + 'ms');
  fill.style.setProperty('--delay', -elapsed + 'ms');
  fill.style.setProperty('--at', String(Math.min(0.92, elapsed / card.usual_ms)));
  return [el('span', { class: 'bar', 'aria-hidden': 'true' }, fill)];
}

// A provider can finish without naming a file; its frame then stays empty.
function imagePlate(run, card, frame) {
  if (!card.image) return [];
  const url = imageUrl(run, card);
  const image = el('img', { alt: card.name + ' image for: ' + run.prompt, loading: 'lazy', decoding: 'async' });
  image.addEventListener('load', () => image.classList.add('shown'), { once: true });
  image.addEventListener('error', () => {
    frame.node.classList.add('missing');
    frame.plate.replaceChildren(el('p', { class: 'gone', text: 'moved or deleted' }));
  }, { once: true });
  image.src = url;
  const view = el('button', { type: 'button', class: 'view', 'data-key': 'view' }, image);
  view.addEventListener('click', () => openLoupe(run.id, card.name));
  return [view, el('div', { class: 'actions slab' }, revealButton(() => url, frame.note), fullSizeLink(url))];
}

// The error text, clamped to the square; "show all" appears only when the text runs past it.
function errorPlate(run, card, frame) {
  if (!card.error) return [];
  const text = el('pre', { class: 'error', text: card.error });
  requestAnimationFrame(() => {
    if (text.scrollHeight <= text.clientHeight + 1) return;
    const more = el('button', { type: 'button', class: 'more', 'aria-expanded': 'false', 'data-key': 'more', text: 'show all' });
    more.addEventListener('click', () => {
      const open = frame.node.classList.toggle('expanded');
      more.setAttribute('aria-expanded', String(open));
      more.textContent = open ? 'show less' : 'show all';
    });
    frame.plate.append(more);
  });
  return [text];
}

// What each frame state draws on its plate and adds to the edge print. A frame at work prints
// nothing visible: its plate and fill say it, and screen readers hear "generating".
const FRAME_STATES = {
  waiting: { plate: waitingPlate, word: () => '', atWork: true },
  querying: { plate: waitingPlate, word: card => (card.round > 0 ? 'again' : ''), atWork: true },
  retrying: { plate: waitingPlate, word: card => 'retry ' + card.attempt, atWork: true },
  complete: { plate: imagePlate, word: card => seconds(card.ms) },
  error: { plate: errorPlate, word: () => 'failed' },
  interrupted: { plate: () => [], word: () => 'stopped' },
};

function frameState(run, card) {
  const state = FRAME_STATES[card.state];
  if (!state) throw new Error('unknown frame state "' + card.state + '" for ' + card.name + ' in run ' + run.id);
  return state;
}

function printParts(run, card) {
  const state = frameState(run, card);
  const word = state.word(card);
  return [
    el('span', { class: 'provider', text: card.name }),
    card.model ? el('span', { class: 'model', text: card.model }) : null,
    word ? el('span', { class: 'outcome', text: word }) : null,
    state.atWork ? el('span', { class: 'sr', text: 'generating' }) : null,
  ].filter(Boolean);
}

function frameNode(run, card, entry) {
  const plate = el('div', { class: 'plate' });
  const note = el('p', { class: 'note', 'aria-live': 'polite' });
  const node = el('li', { class: 'frame', 'data-state': card.state });
  const frame = { node, plate, note, entry };
  plate.append(...frameState(run, card).plate(run, card, frame));
  node.append(plate, el('p', { class: 'print' }, ...printParts(run, card)), note);
  return node;
}

function hasImage(entry, card) {
  return card.state === 'complete' && card.image && !entry.frames.get(card.name).node.classList.contains('missing');
}

// ── Strips ───────────────────────────────────────────────────────

// The time left on the retry offer, as a hairline that drains to nothing as the offer closes.
function drain(run) {
  if (!run.retry_seconds || !run.retry_ends_ms) return null;
  const left = Math.max(0, run.retry_ends_ms - Date.now());
  const line = el('span', { class: 'drain', 'aria-hidden': 'true' });
  line.style.setProperty('--from', String(Math.min(1, left / (run.retry_seconds * 1000))));
  line.style.setProperty('--left', left + 'ms');
  return line;
}

// A run's state, as the pill at the right of its folder line says it. A finished run failed when no
// provider brought back an image and at least one said why; one with any image is done, its failed
// frames marked on their own.
const RUN_STATES = {
  working: { word: 'Working' },
  done: { word: 'Done' },
  failed: { word: 'Failed' },
  stopped: { word: 'Stopped' },
};

function runState(run) {
  if (run.status === 'live') return 'working';
  if (run.status === 'interrupted') return 'stopped';
  if (run.status !== 'done') throw new Error('unknown run status "' + run.status + '" for run ' + run.id);
  const failed = run.providers.some(card => card.state === 'error') && !run.providers.some(card => card.image);
  return failed ? 'failed' : 'done';
}

// The card's head, in the sidebar's order: the folder line with the state pill at its right, the
// prompt as the title, how long ago a live run last moved, then the facts line.
function headNode(run) {
  const state = runState(run);
  const when = relative(run.started_at);
  const head = el('header', { class: 'head' },
    el('p', { class: 'identity' },
      el('span', { class: 'folder' }, icon('folder'), el('span', { class: 'folder-name', text: run.session || run.id })),
      el('span', { class: 'word ' + state, text: RUN_STATES[state].word })),
    run.prompt ? el('p', { class: 'prompt', id: 'prompt-' + run.id, text: run.prompt }) : null,
    run.updated_ms ? el('p', { class: 'recency', text: updatedAgo(run.updated_ms) }) : null,
    el('p', { class: 'facts' },
      when ? el('span', { class: 'chip' }, icon('clock'), el('time', { class: 'when', datetime: run.started_at, text: when })) : null,
      run.cwd ? el('span', { class: 'chip cwd', text: run.cwd }) : null));
  if (run.retry && run.retry.length) {
    const note = el('span', { class: 'note', 'aria-live': 'polite' });
    const button = el('button', { type: 'button', class: 'retry', 'data-key': 'retry', 'aria-label': 'Retry failed: ' + run.retry.join(', ') },
      icon('arrow-clockwise'), el('span', { text: 'Retry failed' }), drain(run));
    button.addEventListener('click', () => post('retry/' + encodeURIComponent(run.id), button, note));
    head.append(el('div', { class: 'offer' }, button, note));
  }
  if (run.problem) head.append(el('p', { class: 'problem', text: run.problem }));
  return head;
}

// Replaces a node, keeping keyboard focus on the control of the same data-key in its successor.
function swap(old, next) {
  const focused = old.contains(document.activeElement) && document.activeElement.dataset.key;
  old.replaceWith(next);
  if (focused) {
    const again = next.querySelector('[data-key="' + CSS.escape(focused) + '"]');
    if (again) again.focus();
  }
}

function newStrip(run) {
  const frameList = el('ol', { class: 'frames' });
  const node = el('li', { class: 'strip card', 'data-id': run.id });
  const entry = { run, node, head: null, headKey: '', frameList, frames: new Map(), roundSeen: new Map() };
  node.append(el('article', run.prompt ? { 'aria-labelledby': 'prompt-' + run.id } : { 'aria-label': run.session || run.id }, frameList));
  updateStrip(entry, run);
  return entry;
}

function updateStrip(entry, run) {
  entry.run = run;
  const state = runState(run);
  entry.node.dataset.state = state;
  const headKey = JSON.stringify([state, run.prompt, run.session, run.cwd, run.started_at, run.retry, run.retry_ends_ms, run.problem]);
  if (headKey !== entry.headKey) {
    const head = headNode(run);
    if (entry.head) swap(entry.head, head);
    else entry.frameList.before(head);
    entry.head = head;
    entry.headKey = headKey;
  }
  const recency = entry.head.querySelector('.recency');
  if (recency && run.updated_ms) recency.textContent = updatedAgo(run.updated_ms);
  const seen = new Set();
  let previous = null;
  for (const card of run.providers) {
    seen.add(card.name);
    const key = JSON.stringify(card);
    let frame = entry.frames.get(card.name);
    if (!frame || frame.key !== key) {
      const node = frameNode(run, card, entry);
      if (frame) swap(frame.node, node);
      frame = { key, node };
      entry.frames.set(card.name, frame);
    }
    const slot = previous ? previous.nextSibling : entry.frameList.firstChild;
    if (slot !== frame.node) entry.frameList.insertBefore(frame.node, slot);
    previous = frame.node;
  }
  for (const [name, frame] of entry.frames) {
    if (!seen.has(name)) {
      frame.node.remove();
      entry.frames.delete(name);
    }
  }
}

// ── Sessions ─────────────────────────────────────────────────────

function selectedSession() {
  const match = /^#s=(.+)$/.exec(location.hash);
  if (!match) return null;
  try {
    return decodeURIComponent(match[1]);
  } catch (error) {
    return null;
  }
}

function railRow(label, href, count, live, current, key) {
  const link = el('a', { class: 'session-row', href, 'data-key': key },
    el('span', { class: live ? 'lamp live' : 'lamp', 'aria-hidden': 'true' }),
    el('span', { class: 'name', text: label }),
    el('span', { class: 'count', text: String(count) }),
    live ? el('span', { class: 'sr', text: ', generating' }) : null);
  if (current) link.setAttribute('aria-current', 'page');
  return el('li', null, link);
}

// One row per session, the one with the newest run first, after "All".
function renderRail() {
  const sessions = new Map();
  for (const run of runs) {
    if (!run.session) continue;
    const session = sessions.get(run.session) || { runs: 0, live: false };
    session.runs += 1;
    session.live = session.live || run.status === 'live';
    sessions.set(run.session, session);
  }
  const selected = selectedSession();
  const anyLive = runs.some(run => run.status === 'live');
  const key = JSON.stringify([selected, runs.length, anyLive, [...sessions]]);
  if (key === railKey) return;
  railKey = key;
  const focused = sessionList.contains(document.activeElement) && document.activeElement.dataset.key;
  const rows = [railRow('All', '#', runs.length, anyLive, selected === null, 'all')];
  for (const [name, session] of sessions) {
    rows.push(railRow(name, '#s=' + encodeURIComponent(name), session.runs, session.live, selected === name, 'session:' + name));
  }
  sessionList.replaceChildren(...rows);
  if (focused) {
    const again = sessionList.querySelector('[data-key="' + CSS.escape(focused) + '"]');
    if (again) again.focus();
  }
}

function applyFilter() {
  const selected = selectedSession();
  let shown = 0;
  for (const entry of strips.values()) {
    entry.node.hidden = selected !== null && entry.run.session !== selected;
    if (!entry.node.hidden) shown += 1;
  }
  empty.textContent = runs.length ? 'No runs from ' + selected + '.' : NO_RUNS;
  empty.hidden = shown > 0;
}

// ── Keeping your place ───────────────────────────────────────────

// The first strip on screen and where it stands, so content you are looking at stays put when
// runs land above it. Nothing to keep at the top of the page: there a new run shows itself.
function scrollAnchor() {
  if (window.scrollY <= 0) return null;
  for (const node of stripList.children) {
    if (node.hidden) continue;
    const box = node.getBoundingClientRect();
    if (box.bottom > 0) return { node, top: box.top };
  }
  return null;
}

function keepPlace(anchor) {
  if (!anchor || !anchor.node.isConnected) return;
  const moved = anchor.node.getBoundingClientRect().top - anchor.top;
  if (moved) window.scrollBy(0, moved);
}

function showFresh(count) {
  unseen += count;
  fresh.textContent = unseen + ' new';
  fresh.setAttribute('aria-label', 'Show ' + unseen + (unseen === 1 ? ' new run' : ' new runs'));
  fresh.hidden = false;
}

function clearFresh() {
  unseen = 0;
  fresh.hidden = true;
}

// ── Render ───────────────────────────────────────────────────────

function render(snapshot) {
  const anchor = scrollAnchor();
  runs = snapshot.runs;
  const selected = selectedSession();
  const seen = new Set();
  let previous = null;
  let landed = 0;
  for (const run of runs) {
    seen.add(run.id);
    let entry = strips.get(run.id);
    if (entry) {
      updateStrip(entry, run);
    } else {
      entry = newStrip(run);
      strips.set(run.id, entry);
      if (!firstSnapshot && (selected === null || run.session === selected)) landed += 1;
    }
    const slot = previous ? previous.nextSibling : stripList.firstChild;
    if (slot !== entry.node) stripList.insertBefore(entry.node, slot);
    previous = entry.node;
  }
  for (const [id, entry] of strips) {
    if (!seen.has(id)) {
      entry.node.remove();
      strips.delete(id);
    }
  }
  applyFilter();
  renderRail();
  keepPlace(anchor);
  if (loupeAt && !loupe.hidden && !strips.has(loupeAt.runId)) closeLoupe();
  if (landed && anchor) showFresh(landed);
  firstSnapshot = false;
  const live = runs.filter(run => run.status === 'live').length;
  document.title = live ? '(' + live + ') Image gallery' : 'Image gallery';
}

// ── Loupe ────────────────────────────────────────────────────────

const loupeReveal = revealButton(() => loupeImage.getAttribute('src'), loupeNote);
const loupeFull = fullSizeLink('');
const loupeClose = el('button', { type: 'button', class: 'act', 'aria-label': 'Close', 'data-key': 'close' }, icon('x'));
loupeClose.addEventListener('click', closeLoupe);
document.getElementById('loupe-actions').append(loupeReveal, loupeFull, loupeClose);

function framesWithImages(entry) {
  return entry.run.providers.filter(card => hasImage(entry, card));
}

function showInLoupe() {
  const entry = strips.get(loupeAt.runId);
  const run = entry.run;
  const card = run.providers.find(candidate => candidate.name === loupeAt.name);
  const url = imageUrl(run, card);
  loupeImage.src = url;
  loupeImage.alt = card.name + ' image for: ' + run.prompt;
  loupeFull.href = url;
  loupePrint.replaceChildren(...printParts(run, card));
  loupeNote.textContent = '';
  loupePrompt.textContent = run.prompt;
}

function openLoupe(runId, name) {
  loupeAt = { runId, name };
  showInLoupe();
  clearTimeout(loupeClosing);
  if (!loupe.hidden && loupe.classList.contains('open')) return;
  loupe.hidden = false;
  loupe.focus();
  requestAnimationFrame(() => requestAnimationFrame(() => loupe.classList.add('open')));
}

// Back to the frame on screen when the loupe closed, which may not be the one it opened on.
function closeLoupe() {
  loupe.classList.remove('open');
  const entry = strips.get(loupeAt.runId);
  const frame = entry && entry.frames.get(loupeAt.name);
  const view = frame && frame.node.querySelector('.view');
  (view || document.getElementById('strips')).focus();
  loupeClosing = setTimeout(() => { loupe.hidden = true; }, reducedMotion.matches ? 0 : LOUPE_MS);
}

function stepAcross(direction) {
  const list = framesWithImages(strips.get(loupeAt.runId));
  const next = list[list.findIndex(card => card.name === loupeAt.name) + direction];
  if (next) {
    loupeAt.name = next.name;
    showInLoupe();
  }
}

// To the nearest strip up or down, in the current filter, that has an image: the same provider's
// when it has one there, else the strip's first.
function stepStrips(direction) {
  const order = [...stripList.children].filter(node => !node.hidden).map(node => node.dataset.id);
  for (let i = order.indexOf(loupeAt.runId) + direction; i >= 0 && i < order.length; i += direction) {
    const list = framesWithImages(strips.get(order[i]));
    if (list.length) {
      loupeAt = { runId: order[i], name: (list.find(card => card.name === loupeAt.name) || list[0]).name };
      showInLoupe();
      return;
    }
  }
}

function trapFocus(event) {
  const stops = [...loupe.querySelectorAll('button, a[href]')];
  const at = stops.indexOf(document.activeElement);
  const next = event.shiftKey ? (at <= 0 ? stops.length - 1 : at - 1) : (at + 1) % stops.length;
  stops[next].focus();
}

const LOUPE_KEYS = {
  Escape: closeLoupe,
  ArrowLeft: () => stepAcross(-1),
  ArrowRight: () => stepAcross(1),
  ArrowUp: () => stepStrips(-1),
  ArrowDown: () => stepStrips(1),
  r: () => loupeReveal.click(),
  R: () => loupeReveal.click(),
  Tab: trapFocus,
};

loupe.addEventListener('keydown', event => {
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  const action = LOUPE_KEYS[event.key];
  if (!action) return;
  event.preventDefault();
  action(event);
});

loupe.addEventListener('click', event => {
  if (!event.target.closest('.loupe-image, .loupe-caption, .loupe-actions')) closeLoupe();
});

// ── Wiring ───────────────────────────────────────────────────────

fresh.addEventListener('click', () => {
  window.scrollTo(0, 0);
  clearFresh();
});

window.addEventListener('scroll', () => {
  if (unseen && window.scrollY <= 2) clearFresh();
}, { passive: true });

window.addEventListener('hashchange', () => {
  applyFilter();
  renderRail();
  clearFresh();
  window.scrollTo(0, 0);
});

setInterval(() => {
  for (const time of stripList.querySelectorAll('time.when')) time.textContent = relative(time.dateTime);
  for (const entry of strips.values()) {
    const recency = entry.head.querySelector('.recency');
    if (recency && entry.run.updated_ms) recency.textContent = updatedAgo(entry.run.updated_ms);
  }
}, 30000);

function connect() {
  const source = new EventSource('events');
  source.onopen = () => { connection.textContent = ''; };
  source.onmessage = event => render(JSON.parse(event.data));
  source.onerror = () => {
    if (source.readyState === EventSource.CLOSED) {
      connection.textContent = 'turned away: open the address the image tool printed';
      setTimeout(connect, 5000);
    } else {
      connection.textContent = 'reconnecting';
    }
  };
}

connect();
