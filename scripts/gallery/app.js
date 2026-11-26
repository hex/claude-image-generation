'use strict';

// The gallery: one section per image run, newest first, its providers' frames in fixed columns.
// Every value from a run goes into the page as text (textContent) or as an attribute set through
// the DOM, never as HTML. Strips are kept by run id and frames by provider name, so a
// snapshot rebuilds only the parts that changed and an image already shown never reloads.

const SVG_NS = 'http://www.w3.org/2000/svg';
// Phosphor regular icons, the path data read out of @phosphor-icons/core 2.1.1 (assets/regular).
const ICONS = {
  'folder-open': 'M245,110.64A16,16,0,0,0,232,104H216V88a16,16,0,0,0-16-16H130.67L102.94,51.2a16.14,16.14,0,0,0-9.6-3.2H40A16,16,0,0,0,24,64V208h0a8,8,0,0,0,8,8H211.1a8,8,0,0,0,7.59-5.47l28.49-85.47A16.05,16.05,0,0,0,245,110.64ZM93.34,64,123.2,86.4A8,8,0,0,0,128,88h72v16H69.77a16,16,0,0,0-15.18,10.94L40,158.7V64Zm112,136H43.1l26.67-80H232Z',
  'arrows-out': 'M216,48V96a8,8,0,0,1-16,0V67.31l-42.34,42.35a8,8,0,0,1-11.32-11.32L188.69,56H160a8,8,0,0,1,0-16h48A8,8,0,0,1,216,48ZM98.34,146.34,56,188.69V160a8,8,0,0,0-16,0v48a8,8,0,0,0,8,8H96a8,8,0,0,0,0-16H67.31l42.35-42.34a8,8,0,0,0-11.32-11.32ZM208,152a8,8,0,0,0-8,8v28.69l-42.34-42.35a8,8,0,0,0-11.32,11.32L188.69,200H160a8,8,0,0,0,0,16h48a8,8,0,0,0,8-8V160A8,8,0,0,0,208,152ZM67.31,56H96a8,8,0,0,0,0-16H48a8,8,0,0,0-8,8V96a8,8,0,0,0,16,0V67.31l42.34,42.35a8,8,0,0,0,11.32-11.32Z',
  'trash': 'M216,48H176V40a24,24,0,0,0-24-24H104A24,24,0,0,0,80,40v8H40a8,8,0,0,0,0,16h8V208a16,16,0,0,0,16,16H192a16,16,0,0,0,16-16V64h8a8,8,0,0,0,0-16ZM96,40a8,8,0,0,1,8-8h48a8,8,0,0,1,8,8v8H96Zm96,168H64V64H192ZM112,104v64a8,8,0,0,1-16,0V104a8,8,0,0,1,16,0Zm48,0v64a8,8,0,0,1-16,0V104a8,8,0,0,1,16,0Z',
  'pencil-simple': 'M227.31,73.37,182.63,28.68a16,16,0,0,0-22.63,0L36.69,152A15.86,15.86,0,0,0,32,163.31V208a16,16,0,0,0,16,16H92.69A15.86,15.86,0,0,0,104,219.31L227.31,96a16,16,0,0,0,0-22.63ZM92.69,208H48V163.31l88-88L180.69,120ZM192,108.68,147.31,64l24-24L216,84.68Z',
  'x': 'M205.66,194.34a8,8,0,0,1-11.32,11.32L128,139.31,61.66,205.66a8,8,0,0,1-11.32-11.32L116.69,128,50.34,61.66A8,8,0,0,1,61.66,50.34L128,116.69l66.34-66.35a8,8,0,0,1,11.32,11.32L139.31,128Z',
};

const stripList = document.getElementById('strip-list');
const empty = document.getElementById('empty');
const sessionList = document.getElementById('sessions');
const connection = document.getElementById('connection');
const here = document.getElementById('here');
const runCount = document.getElementById('run-count');
const fresh = document.getElementById('fresh');
const loupe = document.getElementById('loupe');
const loupeImage = document.getElementById('loupe-image');
const loupePrint = document.getElementById('loupe-print');
const loupeNote = document.getElementById('loupe-note');
const loupePrompt = document.getElementById('loupe-prompt');
const themeInputs = [...document.querySelectorAll('.theme input')];
const deleteProject = document.getElementById('delete-project');
const confirmDialog = document.getElementById('confirm');
const confirmTitle = document.getElementById('confirm-title');
const confirmBody = document.getElementById('confirm-body');
const confirmFiles = document.getElementById('confirm-files');
const confirmCancel = document.getElementById('confirm-cancel');
const confirmDelete = document.getElementById('confirm-delete');

// The four providers run-all.sh can run, in the order of their columns, with the names the page
// shows. A frame of any other provider takes the first free cell.
const PROVIDERS = [['gemini', 'Gemini'], ['openai', 'OpenAI'], ['xai', 'xAI'], ['openrouter', 'OpenRouter']];
const PROVIDER_NAMES = new Map(PROVIDERS);
const THEME_KEY = 'gallery-theme';
// A run started within this long ago shows full size; an older one is a compact strip.
const FULL_SIZE_MS = 24 * 60 * 60 * 1000;

const ON_MAC = /Mac/.test(navigator.platform);
const REVEAL_LABEL = ON_MAC ? 'Reveal in Finder' : 'Show in folder';
const RESEND_KEYS = ON_MAC ? '\u2318\u21a9' : 'Ctrl+\u21a9';
const NO_RUNS = 'No image runs yet. Images from Claude Code show up here while they generate.';
const TITLE = 'Gallery \u00b7 Image Generation';
const LOUPE_MS = 200;
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const clock = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const dayAndClock = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });

// run id -> { run, node, head, headKey, recency, frameList, frames: Map(provider -> { key, node }), roundSeen, editor }
const strips = new Map();
let runs = [];
let railKey = '';
let unseen = 0;
let firstSnapshot = true;
let loupeAt = null;
let loupeClosing = 0;
// What the open delete dialog asks to delete: { ids, empties, busy }, or null. empties is true when
// the runs are every run of the project in view, so the page goes back to All projects once they go.
let deleting = null;

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

// Auto leaves the color scheme to the system, through the stylesheet; Light and Dark pin it.
function applyTheme(choice) {
  if (choice === 'auto') delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = choice;
  for (const input of themeInputs) input.checked = input.value === choice;
}

function savedTheme() {
  const saved = localStorage.getItem(THEME_KEY);
  return saved === 'light' || saved === 'dark' ? saved : 'auto';
}

applyTheme(savedTheme());

function setText(node, text) {
  if (node.textContent !== text) node.textContent = text;
}

function providerName(name) {
  return PROVIDER_NAMES.get(name) || name;
}

// A provider's column, 1 to 4, or 0 for a provider outside the four.
function providerColumn(name) {
  return PROVIDERS.findIndex(([key]) => key === name) + 1;
}

// The providers' cards in the order of their columns; any other provider after the four.
function inColumns(cards) {
  const order = card => providerColumn(card.name) || PROVIDERS.length + 1;
  return [...cards].sort((a, b) => order(a) - order(b));
}

function seconds(ms) {
  return /^[0-9]+$/.test(ms) ? (Number(ms) / 1000).toFixed(1) + ' s' : '';
}

// "just now" and "4 min ago" within the hour, the clock within the day, then the date and the clock.
function relative(iso) {
  const at = new Date(iso);
  if (Number.isNaN(at.getTime())) return '';
  const minutes = Math.floor((Date.now() - at.getTime()) / 60000);
  if (minutes < 1) return 'just now';
  if (minutes < 60) return minutes + ' min ago';
  if (minutes < 24 * 60) return clock.format(at);
  return dayAndClock.format(at);
}

// "Updated 10 s ago", from when a live run last moved, as the sidebar's recency line reads.
function updatedAgo(ms) {
  const seconds = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  const age = seconds < 60 ? seconds + ' s' : seconds < 3600 ? Math.floor(seconds / 60) + ' min' : Math.floor(seconds / 3600) + ' h';
  return 'Updated ' + age + ' ago';
}

// The time since a frame's round began, as its caption counts it while it works: "18 s" within the
// minute, then "4:02".
function elapsed(since) {
  if (Number.isNaN(since)) return '';
  const spent = Math.max(0, Math.floor((Date.now() - since) / 1000));
  return spent < 60 ? spent + ' s' : Math.floor(spent / 60) + ':' + String(spent % 60).padStart(2, '0');
}

// The time left on a retry offer, as m:ss.
function timeLeft(endsMs) {
  const left = Math.max(0, Math.ceil((endsMs - Date.now()) / 1000));
  return Math.floor(left / 60) + ':' + String(left % 60).padStart(2, '0');
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

// When a frame's round began: the run's start for the first round, the moment this page first saw
// a later one.
function roundBegan(run, card, entry) {
  const round = card.name + '/' + card.round;
  if (!entry.roundSeen.has(round)) entry.roundSeen.set(round, card.round > 0 ? Date.now() : Date.parse(run.started_at));
  return entry.roundSeen.get(round);
}

// "Attempt 3 of 4" from a retrying record's "2/3", which counts retries: retry 2 of at most 3 is
// the third request of at most four.
function retryWords(attempt) {
  const match = /^([0-9]+)\/([0-9]+)$/.exec(attempt);
  return match ? 'Attempt ' + (Number(match[1]) + 1) + ' of ' + (Number(match[2]) + 1) : '';
}

// A frame at work: what it is doing, in the middle, over the usual time or the retry under way, and
// a rule along its foot that fills over the usual time from when its round began. No usual time,
// no rule.
function waitingPlate(run, card, frame) {
  const retrying = card.state === 'retrying';
  const label = retrying ? 'Retrying' : card.state === 'waiting' ? 'Waiting' : 'Generating';
  const sub = retrying ? retryWords(card.attempt) : card.usual_ms ? 'usually ~' + Math.round(card.usual_ms / 1000) + ' s' : '';
  const parts = [el('div', { class: 'pending' },
    el('span', { class: 'pending-label', text: label }),
    sub ? el('span', { class: 'pending-sub', text: sub }) : null)];
  if (!card.usual_ms) return parts;
  const began = roundBegan(run, card, frame.entry);
  const spent = Number.isNaN(began) ? 0 : Math.max(0, Date.now() - began);
  const bar = el('span', { class: 'bar', 'aria-hidden': 'true' });
  bar.style.setProperty('--usual', card.usual_ms + 'ms');
  bar.style.setProperty('--delay', -spent + 'ms');
  bar.style.setProperty('--at', String(Math.min(0.92, spent / card.usual_ms)));
  parts.push(bar);
  return parts;
}

// A provider can finish without naming a file; its frame then stays empty.
function imagePlate(run, card, frame) {
  if (!card.image) return [];
  const url = imageUrl(run, card);
  const image = el('img', { alt: providerName(card.name) + ' image for: ' + run.prompt, loading: 'lazy', decoding: 'async' });
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

// A JSON string's contents as text; as written, when they do not parse.
function jsonText(contents) {
  try {
    return JSON.parse('"' + contents + '"');
  } catch (error) {
    return contents;
  }
}

// A provider's error file, read for its plate. The provider scripts write "<Provider> API returned
// HTTP <status>: <message>", the message being the API's error.message or, when it has none, the
// whole response body, sometimes ending "(after N retries)"; their other failures are free text
// with no status. The server cuts a long file short, so a body here can be partial JSON and is read
// by pattern, not parsed. Gives the status and any error code the text names ("Error" when it names
// no status), the message without the prefix, and the whole text.
function readError(text) {
  const full = text.trim();
  const status = /\bHTTP ([0-9]{3})\b/.exec(full);
  const code = /"code"\s*:\s*"([A-Za-z][\w.-]*)"/.exec(full);
  let summary = full.split(/\n\s*\n/)[0].replace(/^[^\n]*?\bHTTP [0-9]{3}\)?:\s*/, '');
  const message = /"(?:message|error)"\s*:\s*"((?:[^"\\]|\\.)*)"/.exec(summary);
  if (/^[{[]/.test(summary) && message) summary = jsonText(message[1]);
  summary = summary.trim();
  return {
    code: [status ? 'HTTP ' + status[1] : 'Error', code ? code[1] : null].filter(Boolean).join(' \u00b7 '),
    summary: summary.charAt(0).toUpperCase() + summary.slice(1),
    full,
  };
}

// A failed frame: the status and code, the message, and "Full error" to open the whole file in
// place. The button shows when the file holds more than the message, or when the message runs
// past the square. A frame drawn while its run is filtered out has no size yet, so that check runs
// whenever it gets one.
function errorPlate(run, card, frame) {
  const error = readError(card.error || '');
  frame.plate.title = error.summary || error.code;
  const message = error.summary
    ? el('p', { class: 'message', text: error.summary })
    : el('p', { class: 'message quiet', text: 'The provider saved no error text.' });
  const parts = [el('p', { class: 'code', text: error.code }), message];
  if (!error.full) return parts;
  const more = el('button', { type: 'button', class: 'more', 'aria-expanded': 'false', 'data-key': 'more', text: 'Full error' });
  more.addEventListener('click', () => {
    const open = frame.node.classList.toggle('expanded');
    more.setAttribute('aria-expanded', String(open));
    more.textContent = open ? 'Show less' : 'Full error';
  });
  parts.push(el('pre', { class: 'full-error', text: error.full }), more);
  if (error.full === error.summary) {
    more.hidden = true;
    const sized = new ResizeObserver(() => {
      if (message.scrollHeight <= message.clientHeight + 1) return;
      sized.disconnect();
      more.hidden = false;
    });
    sized.observe(message);
  }
  return parts;
}

// The seconds a frame at work has been at it, counted up by the page's clock.
function elapsedSecs(run, card, entry) {
  const began = roundBegan(run, card, entry);
  return el('span', { class: 'secs', 'data-since': String(began), text: elapsed(began) });
}

// What each frame state draws on its plate and at the right of its caption.
const FRAME_STATES = {
  waiting: { plate: waitingPlate, secs: elapsedSecs },
  querying: { plate: waitingPlate, secs: elapsedSecs },
  retrying: { plate: waitingPlate, secs: elapsedSecs },
  complete: { plate: imagePlate, secs: (run, card) => el('span', { class: 'secs', text: seconds(card.ms) }) },
  error: { plate: errorPlate, secs: () => el('span', { class: 'secs', text: 'Failed' }) },
  interrupted: { plate: () => [el('span', { class: 'stopped-label', text: 'Stopped' })], secs: () => el('span', { class: 'secs' }) },
};

function frameState(run, card) {
  const state = FRAME_STATES[card.state];
  if (!state) throw new Error('unknown frame state "' + card.state + '" for ' + card.name + ' in run ' + run.id);
  return state;
}

// The loupe's facts line for a frame with an image: provider, model, seconds.
function printParts(run, card) {
  return [
    el('span', { class: 'provider', text: providerName(card.name) }),
    card.model ? el('span', { class: 'model', text: card.model }) : null,
    card.ms ? el('span', { text: seconds(card.ms) }) : null,
  ].filter(Boolean);
}

function frameNode(run, card, entry) {
  const plate = el('div', { class: 'plate' });
  const note = el('p', { class: 'note', 'aria-live': 'polite' });
  const node = el('li', { class: 'frame', 'data-state': card.state });
  const column = providerColumn(card.name);
  if (column) node.style.setProperty('--col', String(column));
  const frame = { node, plate, note, entry };
  const state = frameState(run, card);
  plate.append(...state.plate(run, card, frame));
  const caption = el('p', { class: 'caption' },
    el('span', { class: 'provider', text: providerName(card.name) }),
    state.secs(run, card, entry),
    card.model ? el('span', { class: 'model', text: card.model }) : null);
  node.append(plate, caption, note);
  return node;
}

function hasImage(entry, card) {
  return card.state === 'complete' && card.image && !entry.frames.get(card.name).node.classList.contains('missing');
}

// ── Runs ─────────────────────────────────────────────────────────

// A run's state, as the dot and word that open its line say it. A finished run failed when no
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

// When the run started; a run at work says "Started".
function whenNode(run) {
  const when = relative(run.started_at);
  if (!when) return null;
  const time = el('time', { class: 'when', datetime: run.started_at, text: when });
  return run.status === 'live' ? el('span', { class: 'fact' }, 'Started ', time) : el('span', { class: 'fact' }, time);
}

// The run's head: its line (state, folder, time, how long ago a live run last moved, then Edit
// prompt when the run can be resent and the retry offer while it is open), the prompt under it, and
// any problem reading the run.
function headNode(run) {
  const state = runState(run);
  const line = el('div', { class: 'line' },
    el('span', { class: 'fact state ' + state, text: RUN_STATES[state].word }),
    el('span', { class: 'fact folder', title: run.cwd, text: run.session || run.id }),
    whenNode(run),
    run.updated_ms ? el('span', { class: 'fact recency', text: updatedAgo(run.updated_ms) }) : null);
  if (run.resendable) {
    const edit = el('button', { type: 'button', class: 'edit-prompt', 'data-key': 'edit', 'aria-expanded': 'false' },
      icon('pencil-simple'), el('span', { text: 'Edit prompt' }));
    edit.addEventListener('click', () => openEditor(strips.get(run.id)));
    line.append(edit);
  }
  if (run.retry && run.retry.length) {
    const note = el('span', { class: 'note', 'aria-live': 'polite' });
    const left = run.retry_seconds && run.retry_ends_ms
      ? el('span', { class: 'left', 'data-ends': String(run.retry_ends_ms), text: timeLeft(run.retry_ends_ms) })
      : null;
    const button = el('button', { type: 'button', class: 'retry', 'data-key': 'retry', 'aria-label': 'Retry failed: ' + run.retry.map(providerName).join(', ') },
      el('span', { text: 'Retry failed' }), left);
    button.addEventListener('click', () => post('retry/' + encodeURIComponent(run.id), button, note));
    line.append(el('span', { class: 'offer' }, button, note));
  }
  if (run.status !== 'live') {
    const trash = el('button', { type: 'button', class: 'trash', 'data-key': 'delete', 'aria-label': 'Delete this run and its images', title: 'Delete run' }, icon('trash'));
    trash.addEventListener('click', () => askToDelete([strips.get(run.id).run], null, 0));
    line.append(trash);
  }
  return el('header', { class: 'head' },
    line,
    run.prompt ? el('p', { class: 'prompt', id: 'prompt-' + run.id, text: run.prompt }) : null,
    run.problem ? el('p', { class: 'problem', text: run.problem }) : null);
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
  const node = el('li', { class: 'strip', 'data-id': run.id });
  const entry = { run, node, head: null, headKey: '', frameList, frames: new Map(), roundSeen: new Map(), editor: null };
  node.append(el('article', run.prompt ? { 'aria-labelledby': 'prompt-' + run.id } : { 'aria-label': run.session || run.id }, frameList));
  updateStrip(entry, run);
  return entry;
}

function updateStrip(entry, run) {
  entry.run = run;
  const state = runState(run);
  entry.node.dataset.state = state;
  const headKey = JSON.stringify([state, run.prompt, run.session, run.cwd, run.started_at, run.retry, run.retry_ends_ms, run.problem, run.resendable]);
  if (headKey !== entry.headKey) {
    const head = headNode(run);
    if (entry.head) swap(entry.head, head);
    else entry.frameList.before(head);
    entry.head = head;
    entry.headKey = headKey;
    if (entry.editor && !run.resendable) closeEditor(entry);
    else showEditing(entry);
  }
  const recency = entry.head.querySelector('.recency');
  if (recency && run.updated_ms) recency.textContent = updatedAgo(run.updated_ms);
  const seen = new Set();
  let previous = null;
  for (const card of inColumns(run.providers)) {
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

// ── Resending ────────────────────────────────────────────────────

// Opens the editor that resends a run's prompt in place of the prompt: the prompt to edit, a chip per
// provider with the run's own pressed, Cancel and Resend. It sits beside the run's head, not in it,
// so a snapshot that redraws the head leaves what is typed, and the caret, alone.
function openEditor(entry) {
  if (entry.editor) {
    entry.editor.prompt.focus();
    return;
  }
  const run = entry.run;
  const prompt = el('textarea', { class: 'editor-prompt', 'aria-label': 'Prompt', rows: '3' });
  prompt.value = run.prompt;
  const own = new Set(run.providers.map(card => card.name));
  const chips = PROVIDERS.map(([key, name]) => el('button', { type: 'button', class: 'chip', 'data-provider': key, 'aria-pressed': String(own.has(key)), text: name }));
  const cancel = el('button', { type: 'button', class: 'cancel', text: 'Cancel' });
  const send = el('button', { type: 'button', class: 'send' }, el('span', { text: 'Resend' }), el('kbd', { 'aria-hidden': 'true', text: RESEND_KEYS }));
  const error = el('p', { class: 'editor-error', 'aria-live': 'polite' });
  const node = el('div', { class: 'editor' },
    prompt,
    el('div', { class: 'editor-bar' }, el('span', { class: 'chips', role: 'group', 'aria-label': 'Providers' }, ...chips), cancel, send),
    el('p', { class: 'editor-note', text: 'Starts a new run in ' + (run.session || run.cwd) + '. Claude won\u2019t see its results.' }),
    error);
  const editor = { node, prompt, chips, cancel, send, error, busy: false };
  for (const chip of chips) {
    chip.addEventListener('click', () => {
      chip.setAttribute('aria-pressed', String(chip.getAttribute('aria-pressed') !== 'true'));
      readyToSend(editor);
    });
  }
  prompt.addEventListener('input', () => readyToSend(editor));
  node.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !editor.busy) {
      event.preventDefault();
      closeEditor(entry);
    } else if (event.key === 'Enter' && (ON_MAC ? event.metaKey : event.ctrlKey) && !send.disabled) {
      event.preventDefault();
      resend(entry);
    }
  });
  cancel.addEventListener('click', () => closeEditor(entry));
  send.addEventListener('click', () => resend(entry));
  entry.editor = editor;
  readyToSend(editor);
  showEditing(entry);
  prompt.focus();
  prompt.setSelectionRange(prompt.value.length, prompt.value.length);
}

// Puts the open editor under the run's line in place of its prompt, or brings the prompt back.
function showEditing(entry) {
  const editing = entry.editor !== null;
  const prompt = entry.head.querySelector('.prompt');
  if (prompt) prompt.hidden = editing;
  const button = entry.head.querySelector('.edit-prompt');
  if (button) button.setAttribute('aria-expanded', String(editing));
  if (editing && entry.head.nextSibling !== entry.editor.node) entry.head.after(entry.editor.node);
}

function closeEditor(entry) {
  entry.editor.node.remove();
  entry.editor = null;
  showEditing(entry);
  const button = entry.head.querySelector('.edit-prompt');
  (button || document.getElementById('strips')).focus();
}

// Resend waits for a prompt that is not blank and at least one provider, and for no resend in flight.
function readyToSend(editor) {
  const chosen = editor.chips.some(chip => chip.getAttribute('aria-pressed') === 'true');
  editor.send.disabled = editor.busy || !editor.prompt.value.trim() || !chosen;
  editor.cancel.disabled = editor.busy;
}

// Sends the edited prompt and the chosen providers. The server answers once the new run has started,
// which the next snapshot shows at the top; the editor closes then. Otherwise it stays open with
// the server's reason, so nothing is resent without the page saying what became of it.
async function resend(entry) {
  const editor = entry.editor;
  const providers = editor.chips.filter(chip => chip.getAttribute('aria-pressed') === 'true').map(chip => chip.dataset.provider);
  editor.busy = true;
  editor.send.setAttribute('aria-busy', 'true');
  editor.error.textContent = '';
  readyToSend(editor);
  let failure = null;
  try {
    const response = await fetch('resend/' + encodeURIComponent(entry.run.id), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ prompt: editor.prompt.value, providers }),
    });
    const answer = await response.json().catch(() => ({}));
    if (!response.ok) failure = answer.error || 'The server answered ' + response.status + '.';
  } catch (error) {
    failure = 'Could not reach the gallery server.';
  }
  editor.busy = false;
  editor.send.removeAttribute('aria-busy');
  if (entry.editor !== editor) return;
  if (failure === null) {
    closeEditor(entry);
    return;
  }
  editor.error.textContent = failure;
  readyToSend(editor);
  // Resend was disabled while the request was out, which drops the focus it had; it goes back to the
  // prompt, so Escape and another try work from the keyboard.
  if (document.activeElement === document.body) editor.prompt.focus();
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

function railRow(label, href, count, live, current, key, title) {
  const link = el('a', { class: 'session-row', href, 'data-key': key },
    el('span', { class: live ? 'lamp live' : 'lamp', 'aria-hidden': 'true' }),
    el('span', { class: 'name', text: label }),
    el('span', { class: 'count', text: String(count) }),
    live ? el('span', { class: 'sr', text: ', generating' }) : null);
  if (current) link.setAttribute('aria-current', 'page');
  if (title) link.title = title;
  return el('li', null, link);
}

// One row per session, the one with the newest run first, after "All projects". A session is a working
// directory: two that share a last folder are two rows, told apart by the path in their title.
function renderRail() {
  const sessions = new Map();
  for (const run of runs) {
    if (!run.session) continue;
    const session = sessions.get(run.cwd) || { name: run.session, runs: 0, live: false, finished: 0 };
    session.runs += 1;
    session.live = session.live || run.status === 'live';
    if (run.status !== 'live') session.finished += 1;
    sessions.set(run.cwd, session);
  }
  const selected = selectedSession();
  const anyLive = runs.some(run => run.status === 'live');
  const key = JSON.stringify([selected, runs.length, anyLive, [...sessions]]);
  if (key === railKey) return;
  railKey = key;
  const focused = sessionList.contains(document.activeElement) && document.activeElement.dataset.key;
  const rows = [railRow('All projects', '#', runs.length, anyLive, selected === null, 'all')];
  for (const [cwd, session] of sessions) {
    const row = railRow(session.name, '#s=' + encodeURIComponent(cwd), session.runs, session.live, selected === cwd, 'session:' + cwd, cwd);
    if (session.finished) {
      const button = el('button', { type: 'button', class: 'rail-delete', 'data-key': 'delete:' + cwd, 'aria-label': 'Delete ' + session.name + ' runs and images', title: 'Delete project' }, icon('trash'));
      button.addEventListener('click', () => askToDeleteProject(cwd));
      row.append(button);
    }
    rows.push(row);
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
    entry.node.hidden = selected !== null && entry.run.cwd !== selected;
    if (!entry.node.hidden) shown += 1;
  }
  empty.textContent = runs.length ? 'No runs from ' + selected + '.' : NO_RUNS;
  empty.hidden = shown > 0;
  const session = selected !== null && runs.find(run => run.cwd === selected);
  here.textContent = selected === null ? 'All projects' : session ? session.session : selected;
  deleteProject.hidden = !runs.some(run => run.cwd === selected && run.status !== 'live');
  runCount.textContent = shown + (shown === 1 ? ' run' : ' runs');
  sizeStrips();
}

// The newest run in view, and every run started within FULL_SIZE_MS, show full size; the rest are
// compact strips.
function sizeStrips() {
  let newest = true;
  for (const node of stripList.children) {
    if (node.hidden) continue;
    const started = Date.parse(strips.get(node.dataset.id).run.started_at);
    node.classList.toggle('compact', !newest && !(Date.now() - started < FULL_SIZE_MS));
    newest = false;
  }
}

// ── Deleting ─────────────────────────────────────────────────────

function counted(n, noun) {
  return n + ' ' + noun + (n === 1 ? '' : 's');
}

// Asks before deleting runs, none of them live: the dialog names every image file that goes, marks
// as kept each one a run outside the delete also names, as the server keeps it, and says how many
// of a project's runs stay because they are still generating. Cancel has the focus.
function askToDelete(chosen, project, generating) {
  const ids = chosen.map(run => run.id);
  const named = [...new Set(chosen.flatMap(run => run.images))];
  const others = runs.filter(run => !ids.includes(run.id));
  const shared = named.filter(path => others.some(run => run.images.includes(path)));
  const paths = named.filter(path => !shared.includes(path));
  const selected = selectedSession();
  const empties = selected !== null && runs.filter(run => run.cwd === selected).every(run => ids.includes(run.id));
  deleting = { ids, empties, shared, busy: false };
  confirmTitle.textContent = project ? 'Delete ' + project.name + ' from the gallery?' : 'Delete this run?';
  const removes = project ? 'Removes its ' + counted(chosen.length, 'run') + ' from the gallery' : 'Removes it from the gallery';
  const files = paths.length ? ' and deletes ' + counted(paths.length, 'image') + ' from disk.' : named.length ? '. It deletes no images.' : '. ' + (project ? 'They have' : 'It has') + ' no saved images.';
  const keeps = shared.length ? ' ' + counted(shared.length, 'image') + ' another run uses ' + (shared.length === 1 ? 'stays' : 'stay') + '.' : '';
  const stays = generating ? ' ' + counted(generating, 'run') + ' still generating ' + (generating === 1 ? 'stays' : 'stay') + '.' : '';
  confirmBody.textContent = removes + files + keeps + stays + ' This can\u2019t be undone.';
  confirmFiles.replaceChildren(
    ...paths.map(path => el('li', { text: path })),
    ...shared.map(path => el('li', { text: path + ': kept, another run uses it' })),
  );
  confirmFiles.hidden = !named.length;
  confirmDelete.hidden = false;
  confirmDelete.disabled = false;
  confirmCancel.disabled = false;
  confirmCancel.textContent = 'Cancel';
  confirmDialog.showModal();
  confirmCancel.focus();
}

// A project's runs that are not live; those at work stay.
function askToDeleteProject(cwd) {
  const own = runs.filter(run => run.cwd === cwd);
  const generating = own.filter(run => run.status === 'live').length;
  askToDelete(own.filter(run => run.status !== 'live'), { name: own[0].session, cwd }, generating);
}

// Sends the runs the dialog listed, by id, so a run it did not list never goes. When every one went
// the dialog closes; otherwise it says what the server deleted and why each run it kept stayed.
async function deleteListed() {
  const asked = deleting;
  asked.busy = true;
  confirmDelete.disabled = true;
  confirmCancel.disabled = true;
  let answer = null;
  try {
    const response = await fetch('delete/' + asked.ids.map(encodeURIComponent).join('/'), { method: 'POST' });
    answer = await response.json();
  } catch (error) {
    answer = null;
  }
  asked.busy = false;
  // A file a run of this request named stays when a run the page did not list names it too.
  const outcomes = answer && Array.isArray(answer.kept) ? [...answer.deleted, ...answer.kept] : [];
  const gone = new Set(outcomes.flatMap(run => [...(run.removed || []), ...(run.missing || [])]));
  const unforeseen = outcomes.flatMap(run => run.shared || [])
    .filter(file => !gone.has(file.path) && !asked.shared.includes(file.path));
  if (answer && Array.isArray(answer.kept) && !answer.kept.length && !unforeseen.length) {
    confirmDialog.close();
    if (asked.empties) location.hash = '';
    document.getElementById('strips').focus();
    return;
  }
  confirmDelete.hidden = true;
  confirmCancel.disabled = false;
  confirmCancel.textContent = 'Close';
  confirmCancel.focus();
  if (!answer || !Array.isArray(answer.kept)) {
    confirmTitle.textContent = 'Could not delete';
    confirmBody.textContent = answer && answer.error ? answer.error : 'Could not reach the gallery server.';
    confirmFiles.hidden = true;
    return;
  }
  const images = outcomes.reduce((sum, run) => sum + (run.removed ? run.removed.length : 0), 0);
  confirmTitle.textContent = answer.deleted.length || images ? 'Not everything was deleted' : 'Nothing was deleted';
  const done = answer.deleted.length || images ? 'Deleted ' + counted(answer.deleted.length, 'run') + ' and ' + counted(images, 'image') + '. ' : '';
  const kept = [answer.kept.length && counted(answer.kept.length, 'run'), unforeseen.length && counted(unforeseen.length, 'image')];
  confirmBody.textContent = done + 'Kept ' + kept.filter(Boolean).join(' and ') + ':';
  confirmFiles.replaceChildren(
    ...answer.kept.flatMap(run => [
      el('li', { text: run.error }),
      ...(run.refused || []).map(file => el('li', { text: file.path + ': ' + file.reason })),
    ]),
    ...unforeseen.map(file => el('li', { text: file.path + ': ' + file.reason })),
  );
  confirmFiles.hidden = false;
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
      if (!firstSnapshot && (selected === null || run.cwd === selected)) landed += 1;
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
  document.title = live ? '(' + live + ') ' + TITLE : TITLE;
}

// ── Loupe ────────────────────────────────────────────────────────

const loupeReveal = revealButton(() => loupeImage.getAttribute('src'), loupeNote);
const loupeFull = fullSizeLink('');
const loupeClose = el('button', { type: 'button', class: 'act', 'aria-label': 'Close', 'data-key': 'close' }, icon('x'));
loupeClose.addEventListener('click', closeLoupe);
document.getElementById('loupe-actions').append(loupeReveal, loupeFull, loupeClose);

function framesWithImages(entry) {
  return inColumns(entry.run.providers).filter(card => hasImage(entry, card));
}

function showInLoupe() {
  const entry = strips.get(loupeAt.runId);
  const run = entry.run;
  const card = run.providers.find(candidate => candidate.name === loupeAt.name);
  const url = imageUrl(run, card);
  loupeImage.src = url;
  loupeImage.alt = providerName(card.name) + ' image for: ' + run.prompt;
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

deleteProject.addEventListener('click', () => askToDeleteProject(selectedSession()));
confirmDelete.addEventListener('click', deleteListed);
confirmCancel.addEventListener('click', () => confirmDialog.close());
// Escape closes the dialog, except while a delete it sent is still unanswered.
confirmDialog.addEventListener('cancel', event => {
  if (deleting && deleting.busy) event.preventDefault();
});
confirmDialog.addEventListener('close', () => { deleting = null; });

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

for (const input of themeInputs) {
  input.addEventListener('change', () => {
    if (input.value === 'auto') localStorage.removeItem(THEME_KEY);
    else localStorage.setItem(THEME_KEY, input.value);
    applyTheme(input.value);
  });
}

// The page's clock: the times, the retry countdowns and the seconds of frames at work, and which
// runs have aged out of full size.
setInterval(() => {
  for (const time of stripList.querySelectorAll('time.when')) setText(time, relative(time.dateTime));
  for (const entry of strips.values()) {
    const recency = entry.head.querySelector('.recency');
    if (recency && entry.run.updated_ms) setText(recency, updatedAgo(entry.run.updated_ms));
  }
  for (const left of stripList.querySelectorAll('.left')) setText(left, timeLeft(Number(left.dataset.ends)));
  for (const secs of stripList.querySelectorAll('.secs[data-since]')) setText(secs, elapsed(Number(secs.dataset.since)));
  sizeStrips();
}, 1000);

function connect() {
  const source = new EventSource('events');
  source.onopen = () => { connection.textContent = 'Live'; };
  source.onmessage = event => render(JSON.parse(event.data));
  source.onerror = () => {
    if (source.readyState === EventSource.CLOSED) {
      connection.textContent = 'Turned away: open the address the image tool printed';
      setTimeout(connect, 5000);
    } else {
      connection.textContent = 'Reconnecting';
    }
  };
}

connect();
