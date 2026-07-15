#!/usr/bin/env node
/**
 * Headless check of session-editor multi-section + editable Skip Steps behavior.
 * Loads workflow-shared.js with a minimal DOM mock (no browser).
 */
'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const ROOT = path.resolve(__dirname, '../..');
const JS_PATH = path.join(ROOT, 'sts-docker/sts/workflow-shared.js');
const WF_PATH = path.join(
  ROOT,
  'sts-docker-helpers/backups/session_editor/hart_session.workflow.json'
);

function makeEl(tag, attrs) {
  const el = {
    tagName: String(tag || 'div').toUpperCase(),
    attrs: Object.assign({}, attrs || {}),
    children: [],
    parent: null,
    hidden: false,
    disabled: false,
    className: '',
    textContent: '',
    title: '',
    value: attrs && attrs.value != null ? String(attrs.value) : '',
    checked: !!(attrs && attrs.checked),
    dataset: {},
    classList: {
      _set: new Set(),
      add(c) { this._set.add(c); },
      remove(c) { this._set.delete(c); },
      toggle(c, on) {
        if (on === undefined) {
          if (this._set.has(c)) this._set.delete(c);
          else this._set.add(c);
          return;
        }
        if (on) this._set.add(c);
        else this._set.delete(c);
      },
      contains(c) { return this._set.has(c); },
    },
    style: {},
    appendChild(child) {
      child.parent = this;
      this.children.push(child);
      return child;
    },
    querySelector(sel) {
      return this.querySelectorAll(sel)[0] || null;
    },
    querySelectorAll(sel) {
      const out = [];
      const walk = (node) => {
        if (match(node, sel)) out.push(node);
        (node.children || []).forEach(walk);
      };
      walk(this);
      return out;
    },
    closest(sel) {
      let n = this;
      while (n) {
        if (match(n, sel)) return n;
        n = n.parent;
      }
      return null;
    },
    matches(sel) {
      return match(this, sel);
    },
    setAttribute(k, v) { this.attrs[k] = String(v); },
    getAttribute(k) {
      if (k === 'data-empty-label') return this.attrs['data-empty-label'] || null;
      if (k === 'data-summary-label') return this.attrs['data-summary-label'] || null;
      if (k === 'data-all-label') return this.attrs['data-all-label'] || null;
      if (k === 'data-count-summary') return this.attrs['data-count-summary'] || null;
      return this.attrs[k] != null ? String(this.attrs[k]) : null;
    },
    addEventListener() {},
  };
  if (attrs) {
    Object.keys(attrs).forEach((k) => {
      if (k === 'checked' || k === 'value') return;
      if (k.startsWith('data-')) el.attrs[k] = String(attrs[k]);
      else el.attrs[k] = attrs[k];
    });
  }
  return el;
}

function match(node, sel) {
  if (!node || !sel) return false;
  if (sel === '[data-checkbox-dropdown]') return !!(node.attrs && node.attrs['data-checkbox-dropdown'] != null);
  if (sel === '[data-cdd-toggle]') return !!(node.attrs && node.attrs['data-cdd-toggle'] != null);
  if (sel === '[data-cdd-menu]') return !!(node.attrs && node.attrs['data-cdd-menu'] != null);
  if (sel === '[data-cdd-opt]') return !!(node.attrs && node.attrs['data-cdd-opt'] != null);
  if (sel === '[data-cdd-opt]:checked') {
    return !!(node.attrs && node.attrs['data-cdd-opt'] != null && node.checked);
  }
  if (sel === '[data-param]') return !!(node.attrs && node.attrs['data-param'] != null);
  if (sel === '[data-cdd-option]') return !!(node.attrs && node.attrs['data-cdd-option'] != null);
  if (sel === '.cdd-opt-lbl') return node.className === 'cdd-opt-lbl' || (node.attrs && node.attrs.class === 'cdd-opt-lbl');
  if (sel.startsWith('[data-cdd-opt][value="') && sel.endsWith('"]')) {
    const v = sel.slice('[data-cdd-opt][value="'.length, -2);
    return !!(node.attrs && node.attrs['data-cdd-opt'] != null && node.value === v);
  }
  return false;
}

function parseHtmlFragment(html) {
  // Minimal parser for our checkbox-dropdown markup.
  const root = makeEl('div');
  // toggle button text
  const toggleMatch = html.match(/data-cdd-toggle[^>]*>([^<]*)</);
  const emptyLabel = (html.match(/data-empty-label="([^"]*)"/) || [])[1] || '';
  const allLabel = (html.match(/data-all-label="([^"]*)"/) || [])[1] || '';
  const summaryLabel = (html.match(/data-summary-label="([^"]*)"/) || [])[1] || 'sections';
  const countSummary = /data-count-summary="1"/.test(html);
  const dd = makeEl('div', {
    'data-checkbox-dropdown': '',
    'data-empty-label': emptyLabel,
    'data-summary-label': summaryLabel,
  });
  if (allLabel) dd.attrs['data-all-label'] = allLabel;
  if (countSummary) dd.attrs['data-count-summary'] = '1';
  const toggle = makeEl('button', { 'data-cdd-toggle': '' });
  toggle.textContent = toggleMatch ? toggleMatch[1] : '';
  dd.appendChild(toggle);
  const menu = makeEl('div', { 'data-cdd-menu': '' });
  const re = /data-cdd-opt value="([^"]*)"([^>]*)>/g;
  let m;
  while ((m = re.exec(html))) {
    const opt = makeEl('input', { 'data-cdd-opt': '', value: m[1] });
    opt.checked = /\bchecked\b/.test(m[2]);
    const lab = makeEl('label', { 'data-cdd-option': '' });
    const span = makeEl('span');
    span.className = 'cdd-opt-lbl';
    span.textContent = m[1];
    lab.appendChild(opt);
    lab.appendChild(span);
    menu.appendChild(lab);
  }
  dd.appendChild(menu);
  const hidden = makeEl('input', { 'data-param': 'run_sections', value: '' });
  dd.appendChild(hidden);
  root.appendChild(dd);
  return root;
}

function buildHarness(recipe) {
  const ids = {
    'run-section-host': makeEl('div'),
    'run-section': makeEl('input', { value: '' }),
    'run-start': makeEl('input', { value: '1' }),
    'run-stop': makeEl('input', { value: '1' }),
    'run-skip': makeEl('input', { value: '' }),
    'run-skip-wrap': makeEl('label'),
    'steps-list': makeEl('div'),
    'steps-preview': makeEl('div'),
    'step-count': makeEl('span'),
  };

  const document = {
    activeElement: null,
    body: makeEl('body'),
    getElementById(id) { return ids[id] || null; },
    querySelectorAll() { return []; },
    addEventListener() {},
  };
  const window = { document };
  global.window = window;
  global.document = document;

  // Patch innerHTML setter for host.
  Object.defineProperty(ids['run-section-host'], 'innerHTML', {
    set(html) {
      this.children = [];
      const frag = parseHtmlFragment(String(html || ''));
      frag.children.forEach((c) => this.appendChild(c));
    },
    get() { return ''; },
  });

  const code = fs.readFileSync(JS_PATH, 'utf8');
  // eslint-disable-next-line no-eval
  eval(code);
  const W = window.WorkflowUI;
  assert.ok(W, 'WorkflowUI missing');

  W.recipe = recipe;
  W.previewMode = false;
  W.catalogMap = W.catalogMap || {};
  W.runOptions = {};
  W.escapeHtml = (s) => String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');

  // optionsForParam is used while building; ensure stable.
  W.syncRunSectionSelect();
  W.applyRunSection();
  return { W, ids, document };
}

function checkedIds(W) {
  return W.getSelectedRunSectionIds().slice().sort();
}

function toggleText(ids) {
  const t = ids['run-section-host'].querySelector('[data-cdd-toggle]');
  return t ? t.textContent : '';
}

function setChecked(ids, idSet) {
  const root = ids['run-section-host'].querySelector('[data-checkbox-dropdown]');
  root.querySelectorAll('[data-cdd-opt]').forEach((n) => {
    n.checked = idSet.has(n.value);
  });
}

function main() {
  const recipe = JSON.parse(fs.readFileSync(WF_PATH, 'utf8'));
  const { W, ids } = buildHarness(recipe);
  const sections = W.editorSections();
  assert.ok(sections.length >= 3, 'expected several sections, got ' + sections.length);
  console.log('sections:', sections.length);
  sections.slice(0, 6).forEach((s) => {
    console.log('  ', s.id, s.start + '-' + s.stop, s.label);
  });

  let passed = 0;
  const check = (name, fn) => {
    try {
      fn();
      console.log('PASS', name);
      passed++;
    } catch (e) {
      console.error('FAIL', name, '-', e.message);
      throw e;
    }
  };

  check('default All Sections label', () => {
    assert.strictEqual(toggleText(ids), 'All Sections');
    assert.strictEqual(ids['run-skip'].value, '');
    const cov = W.getRunCoverage();
    assert.strictEqual(cov.all, true);
    assert.strictEqual(cov.none, false);
  });

  check('none selected label + coverage.none', () => {
    setChecked(ids, new Set());
    W.syncCheckboxDropdown(ids['run-section-host'].querySelector('[data-checkbox-dropdown]'));
    W.applyRunSection();
    assert.strictEqual(toggleText(ids), '-- Select Sections --');
    assert.strictEqual(W.getRunCoverage().none, true);
  });

  check('two non-contiguous sections seed skip gaps', () => {
    // Pick first and third section so a gap appears when possible.
    const a = sections[0];
    const c = sections[2];
    setChecked(ids, new Set([a.id, c.id]));
    W.syncCheckboxDropdown(ids['run-section-host'].querySelector('[data-checkbox-dropdown]'));
    W.applyRunSection();
    const cov = W.getRunCoverage();
    assert.strictEqual(cov.none, false);
    assert.strictEqual(cov.all, false);
    assert.ok(cov.skipStr, 'expected gap skip, got empty');
    assert.strictEqual(ids['run-skip'].value, cov.skipStr);
    assert.strictEqual(ids['run-start'].value, String(cov.start));
    assert.strictEqual(ids['run-stop'].value, String(cov.stop));
    const label = toggleText(ids);
    assert.ok(/^\d+ sections?$/.test(label), 'expected count label, got ' + label);
    console.log('   skip seeded:', cov.skipStr, 'label:', label);
  });

  check('editable skip + full section skip unchecks it', () => {
    // Select three consecutive-ish sections, then skip the entire middle one.
    const a = sections[0];
    const b = sections[1];
    const c = sections[2];
    setChecked(ids, new Set([a.id, b.id, c.id]));
    W.syncCheckboxDropdown(ids['run-section-host'].querySelector('[data-checkbox-dropdown]'));
    W.applyRunSection();
    const middleSkip = W.formatStepRanges(
      Array.from({ length: b.stop - b.start + 1 }, (_, i) => b.start + i)
    );
    // Keep existing gap skips too (if any) and add middle full skip.
    const combined = [ids['run-skip'].value, middleSkip].filter(Boolean).join(',');
    ids['run-skip'].value = combined;
    W.applyRunSkipEdit({ normalize: true, syncSections: true });
    const selected = new Set(checkedIds(W));
    assert.ok(!selected.has(b.id), 'middle section should be unchecked, still: ' + [...selected]);
    assert.ok(selected.has(a.id), 'section A should remain checked');
    assert.ok(selected.has(c.id), 'section C should remain checked');
    // Skip field must not be wiped by section sync.
    assert.ok(ids['run-skip'].value, 'skip field should keep value');
    const skipSet = W.getRunSkipSet();
    for (let n = b.start; n <= b.stop; n++) {
      assert.ok(skipSet.has(n), 'skip set missing step ' + n);
    }
    console.log('   after full-skip middle:', toggleText(ids), 'skip=', ids['run-skip'].value);
  });

  check('custom in-section skip with All Sections stays All until full section skipped', () => {
    setChecked(ids, new Set(sections.map((s) => s.id)));
    W.syncCheckboxDropdown(ids['run-section-host'].querySelector('[data-checkbox-dropdown]'));
    W.applyRunSection();
    assert.strictEqual(toggleText(ids), 'All Sections');
    // Skip one step inside first multi-step section (not the whole section).
    const s0 = sections[0];
    assert.ok(s0.stop > s0.start, 'first section should span >1 step');
    ids['run-skip'].value = String(s0.start + 1);
    W.applyRunSkipEdit({ normalize: true, syncSections: true });
    assert.strictEqual(toggleText(ids), 'All Sections');
    assert.ok(W.getRunSkipSet().has(s0.start + 1));
  });

  check('parse/format ranges', () => {
    assert.strictEqual(W.formatStepRanges(W.parseStepRanges('1-2,5,8-10')), '1-2,5,8-10');
    assert.strictEqual(W.formatStepRanges(W.parseStepRanges('10-8,3')), '3,8-10');
  });

  check('normalize clamps out-of-range', () => {
    ids['run-skip'].value = '1,99999,abc,2-3';
    const str = W.normalizeRunSkipField({ force: true });
    assert.strictEqual(str, '1-3');
  });

  console.log('\nAll', passed, 'checks passed.');
}

main();
